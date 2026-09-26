#!/usr/bin/env ruby
# frozen_string_literal: true

# asdf may select macOS's old system Ruby when this command runs outside the
# project. Re-exec the installed project Ruby in that case, including test entry points.
if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.3")
  project = File.dirname(File.realpath(__FILE__))
  version = File.read(File.join(project, ".ruby-version")).strip
  interpreter = File.expand_path("~/.asdf/installs/ruby/#{version}/bin/ruby")
  abort "Ruby 3.3+ is required. Install Ruby #{version} or select a newer Ruby in your PATH." unless File.executable?(interpreter)
  exec({ "GEM_HOME" => nil, "GEM_PATH" => nil }, interpreter, File.realpath($PROGRAM_NAME), *ARGV)
end
ENV["BUNDLE_GEMFILE"] = File.join(File.dirname(File.realpath(__FILE__)), "Gemfile")
require "bundler/setup"
require "bigdecimal"
require "csv"
require "date"
require "digest"
require "fileutils"
require "json"
require "nokogiri"
require "open3"
require "optparse"
require "securerandom"
require "sqlite3"
require "time"
require "uri"
require "zip"

module MoneyWizImport
  ROOT = File.expand_path(__dir__)
  PRIVATE = File.join(ROOT, "private")
  class Error < StandardError; end

  def self.normalize(value)
    value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]]+/, " ").strip
  end

  def self.cents(value)
    number = BigDecimal(value.to_s.delete(",")) * 100
    raise Error, "Non-finite amount" unless number.finite?
    number.round.to_i
  end

  def self.money(cents)
    format("%s%d.%02d", cents.negative? ? "-" : "", cents.abs / 100, cents.abs % 100)
  end

  # Merchant rules: normalized merchant => {"category" => path, "always" => true/false}.
  # "always" => false records a declined suggestion so the UI does not ask again.
  def self.validate_rules(rules)
    raise Error, "Merchant rules must be an object" unless rules.is_a?(Hash)
    rules.each do |key, rule|
      valid = key.is_a?(String) && !key.empty? && rule.is_a?(Hash) && rule["category"].is_a?(String) && !rule["category"].empty? && [true, false].include?(rule["always"])
      raise Error, "Invalid merchant rule for #{key.inspect}" unless valid
    end
    rules
  end

  # Payee names: normalized store name (before the first comma) => MoneyWiz payee.
  # Listed merchants are saved with that payee and an empty description.
  def self.validate_payees(payees)
    raise Error, "payees must be an object" unless payees.is_a?(Hash)
    payees.each do |key, name|
      valid = key.is_a?(String) && !key.empty? && name.is_a?(String) && !name.strip.empty?
      raise Error, "Invalid payee for #{key.inspect}" unless valid
    end
    payees.to_h { |key, name| [normalize(key), name.strip] }
  end

  def self.validate_overrides(overrides)
    raise Error, "Category overrides must be an object" unless overrides.is_a?(Hash)
    overrides.each do |id, category|
      raise Error, "Invalid category override for #{id}" unless id.is_a?(String) && (category.nil? || (category.is_a?(String) && !category.empty?))
    end
    overrides
  end

  def self.write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    temp = "#{path}.#{SecureRandom.hex(6)}.tmp"
    File.open(temp, "w", 0o600) { |f| f.write(JSON.pretty_generate(data) + "\n"); f.flush; f.fsync }
    File.rename(temp, path)
    File.open(File.dirname(path)) { |f| f.fsync }
  ensure
    File.delete(temp) if temp && File.exist?(temp)
  end

  # SQLite's online backup includes committed WAL pages. The source is read-only;
  # every SELECT used for reconciliation runs against the resulting copy.
  class Snapshot
    NAME = /\A\d{8}T\d{6}-[0-9a-f]{10}\.sqlite\z/

    def self.take(source, directory: File.join(PRIVATE, "backups"))
      FileUtils.mkdir_p(directory, mode: 0o700)
      path = File.join(directory, "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(5)}.sqlite")
      begin
        input = SQLite3::Database.new(File.expand_path(source), readonly: true)
      rescue SQLite3::CantOpenException
        # MoneyWiz keeps its store inside its app container; macOS lets a process
        # stat the file but not open it until the terminal has Full Disk Access.
        raise Error, "Cannot open the MoneyWiz database #{source}. Check the path in config.json, or grant this terminal app " \
                     "Full Disk Access (System Settings > Privacy & Security > Full Disk Access) and restart it."
      end
      output = SQLite3::Database.new(path)
      backup = SQLite3::Backup.new(output, "main", input, "main")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      loop do
        result = backup.step(4096)
        break if result == SQLite3::Constants::ErrorCode::DONE
        raise Error, "Database backup timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        unless [SQLite3::Constants::ErrorCode::OK, SQLite3::Constants::ErrorCode::BUSY, SQLite3::Constants::ErrorCode::LOCKED].include?(result)
          raise Error, "Database backup failed: #{result}"
        end
        # Wait only while MoneyWiz holds a lock; an unconditional pause made every copy take seconds.
        sleep 0.05 unless result == SQLite3::Constants::ErrorCode::OK
      end
      backup.finish
      backup = nil
      # The copy inherits WAL mode from MoneyWiz; a rollback journal keeps later
      # read-only opens from leaving -wal/-shm files next to the backup.
      output.execute("PRAGMA journal_mode=DELETE")
      raise Error, "Snapshot integrity check failed" unless output.get_first_value("PRAGMA quick_check") == "ok"
      File.chmod(0o600, path)
      path
    ensure
      backup&.finish
      output&.close
      input&.close
    end

    # Retained backups are a safety net, not an archive: keep only the newest ones,
    # and remove journal files left behind by older read-only opens.
    def self.prune(directory, keep:)
      raise Error, "keep_backups must be a positive integer" unless keep.is_a?(Integer) && keep.positive?
      return unless Dir.exist?(directory)
      # Order by write time: names carry seconds only, so two copies taken in the
      # same second would otherwise be ranked by their random suffix.
      kept = Dir.children(directory).grep(NAME).sort_by { |name| [File.mtime(File.join(directory, name)), name] }.last(keep)
      Dir.children(directory).each do |name|
        base = name.sub(/-(wal|shm|journal)\z/, "")
        next unless base.match?(NAME) && !kept.include?(base)
        File.delete(File.join(directory, name))
      end
    end
  end

  class Statement
    attr_reader :transactions, :account_number, :range

    def initialize(path)
      @path = File.expand_path(path)
      Zip::File.open(@path) do |zip|
        workbook = xml(zip.read("xl/workbook.xml"))
        raise Error, "Excel 1904 dates are unsupported" if workbook.at_xpath("//workbookPr")&.[]("date1904") == "1"
        relations = xml(zip.read("xl/_rels/workbook.xml.rels")).xpath("//Relationship").to_h { |r| [r["Id"], r["Target"]] }
        strings = zip.find_entry("xl/sharedStrings.xml") ? xml(zip.read("xl/sharedStrings.xml")).xpath("//si").map { |s| s.xpath(".//t").map(&:text).join } : []
        sheets = workbook.xpath("//sheet").to_h do |s|
          target = relations.fetch(s["id"])
          entry = target.start_with?("/") ? target.delete_prefix("/") : File.expand_path(target, "/xl").delete_prefix("/")
          [s["name"], rows(xml(zip.read(entry)), strings)]
        end
        details = sheets.fetch("Details") { raise Error, "Expected a Bank of Georgia Details sheet" }
        @account_number = details.find { |r| r["A"] == "Account No:" }&.fetch("C")
        raise Error, "Missing statement account number" if @account_number.to_s.empty?
        @range = ["Filter Date From:", "Filter Date To:"].map { |label| Date.strptime(details.find { |r| r["A"] == label }.fetch("C"), "%d/%m/%Y").iso8601 }
        parse(sheets.fetch("Transactions") { raise Error, "Missing Transactions sheet" })
      end
    rescue KeyError, Date::Error, Zip::Error => e
      raise Error, "Invalid bank statement #{@path}: #{e.message}"
    end

    def xml(text)
      Nokogiri::XML(text) { |c| c.strict.nonet }.tap(&:remove_namespaces!)
    end

    def rows(doc, strings)
      doc.xpath("//sheetData/row").map do |row|
        row.xpath("./c").to_h do |cell|
          value = case cell["t"]
                  when "inlineStr" then cell.xpath(".//t").map(&:text).join
                  when "s" then strings.fetch(Integer(cell.at_xpath("./v").text))
                  else cell.at_xpath("./v")&.text
                  end
          [cell["r"].delete("0-9"), value.to_s]
        end.merge("_row" => row["r"].to_i)
      end
    end

    def parse(rows)
      header = rows.first
      raise Error, "Unrecognized statement columns" unless header["A"] == "Date" && header["B"] == "Details"
      currencies = header.select { |key, value| key != "_row" && value.to_s.match?(/\A[A-Z]{3}\z/) }
      raise Error, "No currency columns" if currencies.empty?
      @transactions = rows.drop(1).flat_map do |row|
        next [] if row["A"] == "Balance" || row.values.all? { |v| v.to_s.empty? }
        posted = Date.strptime(row.fetch("A"), "%d/%m/%Y").iso8601
        description = row.fetch("B").strip
        stamp = description[/\bDate: (\d{2}\/\d{2}\/\d{4} \d{2}:\d{2}(?::\d{2})?)/, 1]
        occurred = stamp ? DateTime.strptime(stamp, stamp.length == 19 ? "%d/%m/%Y %H:%M:%S" : "%d/%m/%Y %H:%M").strftime("%Y-%m-%d %H:%M:%S") : "#{posted} 12:00:00"
        merchant = description[/Merchant: ([^;]+)/, 1]&.strip
        counterparty = description[/(?:Sender|Beneficiary): ([^;]+)/, 1]&.strip
        kind = description.include?("Foreign Exchange") ? "FX" : description.split(" - ").first
        # Purchases are titled by merchant. Transfers, FX and other non-purchases
        # keep the bank's row type as their MoneyWiz description, uncategorized,
        # so they are easy to find and reclassify in the app later.
        payee = kind == "Payment" ? merchant&.split(",")&.first || counterparty || kind : kind
        currencies.filter_map do |column, currency|
          next if row[column].to_s.empty?
          amount = MoneyWizImport.cents(row[column])
          next if amount.zero?
          # Purchase identity excludes mutable posting date and export filename.
          payment_code = description[/payment code\s*-\s*(\d+)/i, 1]
          identity = if payment_code
                       [@account_number, currency, amount, "payment-code", payment_code]
                     elsif merchant && stamp
                       [@account_number, currency, amount, occurred, MoneyWizImport.normalize(merchant), description[/Card No: ([^;]+)/, 1]]
                     else
                       [@account_number, currency, amount, occurred, MoneyWizImport.normalize(description)]
                     end
          fingerprint = Digest::SHA256.hexdigest(JSON.generate(identity))
          { "fingerprint" => fingerprint, "currency" => currency, "cents" => amount,
            "posted" => posted, "occurred" => occurred, "merchant" => merchant,
            "payee" => payee, "counterparty" => counterparty, "description" => description, "row" => row["_row"],
            "source" => @path, "kind" => kind,
            "bank_payment_code" => payment_code }
        end
      end
      counts = @transactions.group_by { |t| t["fingerprint"] }.transform_values(&:size)
      ordinals = Hash.new(0)
      @transactions.each do |t|
        ordinals[t["fingerprint"]] += 1
        t["id"] = "bog-v1-#{t['fingerprint']}-#{ordinals[t['fingerprint']]}"
        t["indistinguishable_count"] = counts.fetch(t["fingerprint"])
      end
    end
  end

  class Reference
    attr_reader :accounts, :transactions, :category_paths

    def initialize(path)
      db = SQLite3::Database.new(path, readonly: true)
      db.results_as_hash = true
      entities = db.execute("SELECT Z_ENT,Z_NAME FROM Z_PRIMARYKEY").to_h { |r| [r["Z_ENT"], r["Z_NAME"]] }
      objects = db.execute("SELECT * FROM ZSYNCOBJECT")
      by_pk = objects.to_h { |r| [r["Z_PK"], r] }
      @accounts = objects.select { |r| entities.fetch(r["Z_ENT"]).end_with?("Account") && r["ZNAME"] }.map do |r|
        { "pk" => r["Z_PK"], "gid" => r.fetch("ZGID"), "name" => r.fetch("ZNAME"), "currency" => r.fetch("ZCURRENCYNAME"), "archived" => r["ZARCHIVED"] == 1 }
      end
      categories = objects.select { |r| entities[r["Z_ENT"]] == "Category" }.to_h { |r| [r["Z_PK"], r] }
      @category_paths = categories.keys.to_h do |id|
        names, seen, current = [], [], id
        while current
          raise Error, "Category cycle or missing parent" if seen.include?(current) || !categories.key?(current)
          seen << current
          item = categories.fetch(current)
          names.unshift(item.fetch("ZNAME2"))
          current = item["ZPARENTCATEGORY"]
        end
        [id, names.join("/")]
      end
      assignments = db.execute("SELECT ZTRANSACTION,ZCATEGORY FROM ZCATEGORYASSIGMENT WHERE ZTRANSACTION IS NOT NULL").group_by { |r| r["ZTRANSACTION"] }
      @transactions = objects.filter_map do |r|
        type = entities.fetch(r["Z_ENT"])
        next unless %w[DepositTransaction WithdrawTransaction RefundTransaction TransferDepositTransaction TransferWithdrawTransaction ReconcileTransaction].include?(type)
        account = @accounts.find { |a| a["pk"] == r["ZACCOUNT2"] }
        raise Error, "Transaction without known account" unless account
        next if r["ZVOIDCHEQUE"] == 1
        raise Error, "Transaction missing date or identity" unless r["ZDATE1"] && r["ZGID"]
        paths = (assignments[r["Z_PK"]] || []).map { |a| @category_paths.fetch(a["ZCATEGORY"]) }.uniq
        { "gid" => r["ZGID"], "account" => account["name"], "account_gid" => account["gid"],
          "currency" => account["currency"], "cents" => MoneyWizImport.cents(r.fetch("ZAMOUNT1")),
          "date" => Time.at(r["ZDATE1"] + 978_307_200).localtime.to_date.iso8601,
          "description" => r["ZDESC2"].to_s, "memo" => r["ZNOTES1"].to_s,
          "payee" => by_pk[r["ZPAYEE2"]]&.[]("ZNAME5").to_s,
          "category" => paths.size == 1 ? paths.first : nil, "type" => type,
          "original_currency" => r["ZORIGINALCURRENCY"], "original_cents" => r["ZORIGINALAMOUNT"] && MoneyWizImport.cents(r["ZORIGINALAMOUNT"]) }
      end
    rescue KeyError, SQLite3::Exception => e
      raise Error, "Unsupported MoneyWiz database schema: #{e.message}"
    ensure
      db&.close
    end

    def marker(id)
      @transactions.select { |t| "#{t['description']} #{t['memo']}".include?("[#{id}]") }
    end
  end

  class Planner
    attr_reader :aliases

    def initialize(bank, reference, config, ledger: {}, decisions: {}, categories: {}, rules: {})
      @bank, @reference, @config, @ledger, @decisions = bank, reference, config, ledger, decisions
      @categories, @rules = categories, MoneyWizImport.validate_rules(rules)
      @payees = MoneyWizImport.validate_payees(config.fetch("payees", {}))
      @aliases = {}
    end

    # Rules are keyed by the store name before the first comma, so
    # "Nikora, Tbilisi" and "NIKORA , Batumi" share one rule.
    def self.merchant_key(entry)
      MoneyWizImport.normalize(entry["merchant"].to_s.split(",").first)
    end

    # Precedence: explicit per-row choice, then an "always" merchant rule, then
    # a category learned from repeated consistent matches in this statement.
    def resolve_category(b)
      rule = @rules[Planner.merchant_key(b)]
      if @categories.key?(b["id"])
        [@categories[b["id"]], "decision"]
      elsif b["kind"] != "Payment"
        [nil, nil] # transfers and FX stay uncategorized unless chosen per row
      elsif rule && rule["always"] && rule["category"]
        [rule["category"], "rule"]
      elsif (learned = @aliases.dig(MoneyWizImport.normalize(b["merchant"]), "category"))
        [learned, "learned"]
      else
        [nil, nil]
      end
    end

    def distance(bank, transaction)
      [bank["occurred"][0, 10], bank["posted"]].map { |d| (Date.iso8601(d) - Date.iso8601(transaction["date"])).abs.to_i }.min
    end

    def same_account?(b, t)
      b["account"] == t["account"] && b["currency"] == t["currency"]
    end

    MARKER = /\[(bog-v1-[0-9a-f]{64}-\d+)\]/

    # Transactions already claimed by another bank row are never candidates:
    # rows created by this importer carry a marker, and matched/imported rows
    # are recorded in the ledger. Without this, the second purchase at the same
    # merchant would be flagged as a duplicate of the first one created moments before.
    #
    # A marker alone does not prove authorship: MoneyWiz copies the memo when a
    # record is duplicated or turned into a transfer, so an entry the user wrote
    # by hand can carry someone else's marker. Such a copy stays a candidate
    # unless its marker fits it, or belongs to a row outside this statement;
    # otherwise the bank row it really covers would be proposed as new.
    def pool
      @pool ||= begin
        claimed = @ledger.values.filter_map { |r| r["gid"] if %w[matched imported].include?(r["status"]) }.to_h { |gid| [gid, true] }
        owners = @bank.to_h { |b| [b["id"], b] }
        @reference.transactions.reject do |t|
          next true if claimed[t["gid"]]
          "#{t['description']} #{t['memo']}".scan(MARKER).flatten.any? { |id| !owners.key?(id) || marker_fits?(owners[id], t) }
        end
      end
    end

    # A record created by this importer stays editable in MoneyWiz. Converting one
    # into a transfer replaces it with two legs that both inherit the memo, and
    # duplicating a record copies the memo as well, so one marker can appear on
    # several transactions. Accept the single copy that still carries this row's
    # account, amount and date; failing that, the single one with its account and
    # amount, so an edited date does not hide a record we know about.
    def resolve_marker(b, mark)
      dated = mark.select { |t| marker_fits?(b, t) && t["date"] == b["occurred"][0, 10] }
      return dated.first if dated.size == 1
      undated = mark.select { |t| marker_fits?(b, t) }
      undated.first if undated.size == 1
    end

    def marker_fits?(b, t)
      same_account?(b, t) && b["cents"] == t["cents"]
    end

    # The transaction a remembered match or import still points at, when it is
    # there and consistent with the bank row.
    def mapped_transaction(b, remembered)
      t = @reference.transactions.find { |x| x["gid"] == remembered["gid"] }
      return nil unless t && same_account?(b, t)
      return t if t["cents"] == b["cents"]
      t if remembered["bank_cents"] == b["cents"] && remembered["matched_cents"] == t["cents"]
    end

    def exact_candidates(b, days)
      pool.select { |t| same_account?(b, t) && b["cents"] == t["cents"] && distance(b, t) <= days }
    end

    def build
      @bank.each { |b| b["account"] = @config.fetch("accounts")[b["currency"]] }
      validate_accounts
      edges = @bank.to_h { |b| [b["id"], exact_candidates(b, @config.fetch("match_days", 5))] }
      claims = Hash.new { |h, k| h[k] = [] }
      edges.each { |id, candidates| candidates.each { |t| claims[t["gid"]] << id } }
      selected = {}
      # Resolve reciprocal nearest dates before considering farther candidates.
      # Ties remain unresolved; a transaction is never consumed twice.
      remaining = edges.transform_values(&:dup)
      loop do
        choices = @bank.reject { |b| selected.key?(b["id"]) }.filter_map do |b|
          candidates = remaining[b["id"]]
          next if candidates.empty? || b["indistinguishable_count"] > 1
          best_distance = candidates.map { |t| distance(b, t) }.min
          best = candidates.select { |t| distance(b, t) == best_distance }
          next unless best.size == 1
          next if candidates.size > 1 && best_distance > 1
          [b, best.first, best_distance]
        end
        winners = choices.group_by { |_, t, _| t["gid"] }.filter_map do |_, contenders|
          best = contenders.select { |_, _, d| d == contenders.map(&:last).min }
          best.first if best.size == 1
        end
        break if winners.empty?
        winners.each { |b, t, _| selected[b["id"]] = t }
        used = selected.values.map { |t| t["gid"] }
        remaining.transform_values! { |ts| ts.reject { |t| used.include?(t["gid"]) } }
      end
      # Learn only from reciprocal, unique exact amount matches within one day.
      anchors = @bank.filter_map do |b|
        t = edges[b["id"]].first
        [b, t] if t && edges[b["id"]].size == 1 && claims[t["gid"]].size == 1 && distance(b, t) <= 1 && b["indistinguishable_count"] == 1
      end
      anchors.group_by { |b, _| MoneyWizImport.normalize(b["merchant"]) }.each do |merchant, pairs|
        next if merchant.empty? || pairs.size < 3
        categories = pairs.map { |_, t| t["category"] }.uniq
        titles = pairs.map { |_, t| MoneyWizImport.normalize(t["description"]) }.uniq
        @aliases[merchant] = { "samples" => pairs.size, "category" => categories.size == 1 ? categories.first : nil, "titles" => titles }
      end
      # Records matched in this run are not yet in the ledger, but they are spoken
      # for all the same: a near amount must not point at them as a duplicate.
      taken = selected.values.to_h { |t| [t["gid"], true] }
      entries = @bank.map do |b|
        category, category_source = resolve_category(b)
        raise Error, "Unknown category #{category} for #{b['id']}" if category && !@reference.category_paths.value?(category)
        entry = b.merge("candidates" => edges[b["id"]], "category" => category, "category_source" => category_source)
        entry["moneywiz_payee"] = @payees[Planner.merchant_key(b)] if b["kind"] == "Payment" && @payees.key?(Planner.merchant_key(b))
        mark = @reference.marker(b["id"])
        marked = resolve_marker(b, mark)
        remembered = @ledger[b["id"]]
        mapped = remembered && mapped_transaction(b, remembered)
        if marked
          entry.merge("status" => "existing", "reason" => "import marker", "match_gid" => marked["gid"])
        elsif remembered && remembered["status"] == "skipped"
          entry.merge("status" => "skip", "reason" => "saved skip decision")
        elsif mapped
          entry.merge("status" => "existing", "reason" => "saved mapping", "match_gid" => mapped["gid"])
        elsif remembered && remembered["status"] == "imported"
          # This row was created and verified in an earlier apply. The app record has
          # since been edited, converted into a transfer, or deleted, so neither its
          # GID nor its marker identifies it any more. The ledger is still proof that
          # it was created: proposing it again would duplicate the transaction.
          entry.merge("status" => "existing", "reason" => "imported earlier; its MoneyWiz record was edited or removed since")
        elsif !mark.empty?
          entry.merge("status" => "review", "reason" => "marker conflicts with account/amount or appears more than once")
        elsif remembered
          entry.merge("status" => "review", "reason" => "previous dispatch or mapping unresolved; never automatically retry")
        elsif b["indistinguishable_count"] > 1
          entry.merge("status" => "review", "reason" => "indistinguishable bank rows; ordinal is not a true bank ID")
        elsif b["account"].nil?
          entry.merge("status" => "review", "reason" => "missing account mapping")
        elsif selected[b["id"]]
          entry.merge("status" => "existing", "reason" => "reciprocal exact amount/account and closest date", "match_gid" => selected[b["id"]]["gid"])
        else
          classify_unmatched(entry, taken)
        end
      end
      flag_aggregates(entries, taken)
      entries.each { |entry| entry["base_status"] = entry["status"] }
      apply_decisions(entries)
      duplicates = entries.select { |e| e["match_gid"] }.group_by { |e| e["match_gid"] }.select { |_, es| es.size > 1 }
      entries.each do |e|
        if duplicates.key?(e["match_gid"])
          e.merge!("status" => "review", "reason" => "multiple bank rows claim the same MoneyWiz transaction")
          e.delete("match_gid")
        end
        e["decision_locked"] = @ledger.key?(e["id"]) || !@reference.marker(e["id"]).empty?
        e["matched_transaction"] = @reference.transactions.find { |t| t["gid"] == e["match_gid"] } if e["match_gid"]
      end
      entries
    end

    def flag_aggregates(entries, taken = {})
      # A manual entry can combine several bank charges (e.g. purchase + FX fee,
      # or several ATM withdrawals). Surface these BEFORE calling anything new.
      groups = entries.group_by do |e|
        [e["account"], e["currency"], e["occurred"][0, 10], e["kind"], MoneyWizImport.normalize(e["merchant"] || e["counterparty"] || e["payee"])]
      end
      groups.each_value do |group|
        next unless group.size.between?(2, 10)
        unmatched = group.reject { |e| %w[existing skip].include?(e["status"]) }
        next if unmatched.size < 2
        (2..[unmatched.size, 6].min).each do |count|
          unmatched.combination(count) do |parts|
            next unless parts.map { |e| e["cents"] <=> 0 }.uniq.size == 1
            total = parts.sum { |e| e["cents"] }
            candidates = pool.select { |t| !taken[t["gid"]] && same_account?(parts.first, t) && t["cents"] == total && distance(parts.first, t) <= 1 }
            next if candidates.empty?
            parts.each do |part|
              part.merge!("status" => "review", "reason" => "possible combined manual entry (bank rows #{parts.map { |p| p['row'] }.join(', ')} total #{MoneyWizImport.money(total)})")
              part["candidates"] = (part["candidates"] + candidates).uniq { |t| t["gid"] }
            end
          end
        end
      end
      # Conversely, one bank purchase may have been entered as several app rows.
      entries.select { |e| e["status"] == "new" }.each do |entry|
        nearby = pool.select { |t| !taken[t["gid"]] && same_account?(entry, t) && distance(entry, t) <= 1 && (t["cents"] <=> 0) == (entry["cents"] <=> 0) && t["cents"].abs < entry["cents"].abs }
        next if nearby.size > 20
        (2..[nearby.size, 4].min).each do |count|
          split = nearby.combination(count).find { |parts| parts.sum { |t| t["cents"] } == entry["cents"] }
          next unless split
          entry.merge!("status" => "review", "reason" => "possible split across several MoneyWiz entries", "candidates" => split)
          break
        end
      end
    end

    def validate_accounts
      @config.fetch("accounts").each do |currency, name|
        accounts = @reference.accounts.select { |a| a["name"] == name && a["currency"] == currency && !a["archived"] }
        raise Error, "Account mapping #{currency} -> #{name.inspect} is missing, archived, or ambiguous" unless accounts.size == 1
        compact = name.gsub(/[[:space:]]/, "")
        raise Error, "URL account name collision: #{name}" unless @reference.accounts.count { |a| a["name"].gsub(/[[:space:]]/, "") == compact } == 1
      end
    end

    def classify_unmatched(entry, taken = {})
      nearby = pool.select do |t|
        next false if taken[t["gid"]]
        next false unless same_account?(entry, t) && distance(entry, t) <= @config.fetch("review_days", 10)
        next false unless (entry["cents"] <=> 0) == (t["cents"] <=> 0)
        delta = (entry["cents"] - t["cents"]).abs
        tolerance = [100, (entry["cents"].abs * 0.03).round].max
        title = MoneyWizImport.normalize(t["description"] + " " + t["payee"])
        merchant = MoneyWizImport.normalize(entry["payee"])
        delta <= tolerance || (!merchant.empty? && title.include?(merchant))
      end
      entry["candidates"] = (entry["candidates"] + nearby).uniq { |t| t["gid"] }
      if !entry["candidates"].empty?
        entry.merge("status" => "review", "reason" => "possible duplicate: date, amount, title, or competing match")
      elsif entry["kind"] != "Payment"
        entry.merge("status" => "new", "reason" => "#{entry['kind']}: created uncategorized with that title; adjust in MoneyWiz later")
      else
        entry.merge("status" => "new", "reason" => "no plausible existing transaction")
      end
    end

    def apply_decisions(entries)
      entries.each do |entry|
        decision = @decisions[entry["id"]]
        next unless decision
        # Outstanding dispatches cannot be bypassed by an old 'new' decision.
        next if @ledger.key?(entry["id"]) || !@reference.marker(entry["id"]).empty?
        case decision.fetch("action")
        when "defer"
          entry.merge!("status" => "review", "reason" => "deferred for a later review")
          entry.delete("match_gid")
        when "skip"
          entry.merge!("status" => "skip", "reason" => "explicit skip")
          entry.delete("match_gid")
        when "match"
          t = @reference.transactions.find { |x| x["gid"] == decision.fetch("gid") }
          raise Error, "Invalid match decision for #{entry['id']}" unless t && same_account?(entry, t) && (entry["cents"] <=> 0) == (t["cents"] <=> 0)
          entry.merge!("status" => "existing", "match_gid" => t["gid"], "reason" => "explicit match decision")
        when "new"
          operation = decision["operation"]
          expected = entry["cents"].negative? ? "expense" : "income"
          raise Error, "Operation conflicts with bank amount sign" if operation && operation != expected
          raise Error, "Cannot override indistinguishable rows" if entry["indistinguishable_count"] > 1
          raise Error, "No target account" unless entry["account"]
          category = decision.fetch("category", entry["category"])
          raise Error, "Unknown category #{category}" if category && !@reference.category_paths.value?(category)
          entry.merge!("status" => "new", "reason" => "explicit new decision", "category" => category, "operation" => expected)
          entry["category_source"] = "decision" if decision.key?("category")
          entry.delete("match_gid")
        else
          raise Error, "Unknown decision action"
        end
      end
    end
  end

  # MoneyWiz prints the note right after the title, so a marker on a record titled
  # "Outgoing Transfer" is pure clutter — and those are exactly the records you
  # convert into real transfers by hand afterwards, which scatters or drops the
  # memo anyway. Transfers are left unmarked and recognized through the ledger.
  def self.memo(entry)
    title = entry["moneywiz_payee"] || entry["payee"].to_s
    "[#{entry.fetch('id')}]" unless title.match?(/transfer/i)
  end

  def self.url(entry)
    raise Error, "Only new transactions can be created" unless entry["status"] == "new"
    params = { "account" => entry.fetch("account").gsub(/[[:space:]]/, ""), "amount" => money(entry.fetch("cents").abs),
               "currency" => entry.fetch("currency"), "date" => entry.fetch("occurred"), "save" => "true",
               # Only the merchant name; the bank's full text stays in the plan.
               "description" => entry.fetch("payee").to_s }
    params["memo"] = memo(entry) if memo(entry)
    params["category"] = entry["category"] if entry["category"]
    # Payees are created only for merchants listed in config "payees"; otherwise the
    # merchant name is the description, so bank spelling variations do not multiply payees.
    if entry["moneywiz_payee"]
      params["payee"] = entry["moneywiz_payee"]
      params.delete("description")
    end
    query = URI.encode_www_form(params).gsub("+", "%20")
    "moneywiz://#{entry['cents'].negative? ? 'expense' : 'income'}?#{query}"
  end

  class Runner
    PLAN_CONFIG_KEYS = %w[database timezone accounts match_days review_days payees].freeze

    def initialize(config, state_path: File.join(PRIVATE, "ledger.json"), snapshotter: nil, opener: nil)
      @config, @state_path = config, state_path
      @snapshotter = snapshotter || -> { Snapshot.take(@config.fetch("database")) }
      @opener = opener || lambda do |url|
        _, error, status = Open3.capture3("/usr/bin/open", "-g", url)
        raise Error, "MoneyWiz URL dispatch failed: #{error}" unless status.success?
      end
    end

    def state
      File.exist?(@state_path) ? JSON.parse(File.read(@state_path)) : { "version" => 1, "entries" => {}, "merchant_categories" => {} }
    end

    def ledger
      state.fetch("entries")
    end

    def merchant_rules
      MoneyWizImport.validate_rules(state["merchant_categories"] || {})
    end

    def save(entries, rules = nil)
      MoneyWizImport.write_json(@state_path, { "version" => 1, "entries" => entries, "merchant_categories" => rules || merchant_rules })
    end

    # URLs sent while MoneyWiz is starting are dropped, and the URL itself would
    # launch the app. Apply only talks to an app that has been running for a while.
    def require_running_app(settle_seconds: 90)
      name = @config["app_process"]
      return unless name
      pid = `pgrep -x #{name}`.split.first
      raise Error, "#{name} is not running. Open it, wait until it finished syncing, then run apply again." unless pid
      elapsed = `ps -o etime= -p #{pid}`.strip.split(/[-:]/).map(&:to_i)
      seconds = elapsed.reverse.each_with_index.sum { |v, i| v * [1, 60, 3600, 86_400].fetch(i) }
      if seconds < settle_seconds
        puts "#{name} started #{seconds}s ago; waiting #{settle_seconds - seconds}s for it to settle."
        sleep(settle_seconds - seconds)
      end
    end

    # Clears a "dispatching" reservation whose URL provably never produced a
    # record: MoneyWiz is running, and a fresh backup has no marker for the row.
    def release(id)
      with_lock do
        state = ledger
        entry = state[id]
        raise Error, "No reservation for #{id}" unless entry
        raise Error, "#{id} is #{entry['status']}, not dispatching; nothing to release" unless entry["status"] == "dispatching"
        require_running_app(settle_seconds: 0)
        snapshot = @snapshotter.call
        Snapshot.prune(File.dirname(snapshot), keep: @config.fetch("keep_backups", 1))
        marks = Reference.new(snapshot).marker(id)
        raise Error, "MoneyWiz has #{marks.size} record(s) marked [#{id}]; run a fresh import to reconcile instead" unless marks.empty?
        state.delete(id)
        save(state)
        puts "Released #{id}; the row returns to automatic classification on the next import."
      end
    end

    def with_lock
      FileUtils.mkdir_p(File.dirname(@state_path), mode: 0o700)
      File.open("#{@state_path}.lock", File::RDWR | File::CREAT, 0o600) do |file|
        raise Error, "Another importer is running" unless file.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end

    # Without a decisions file the plan is applied as displayed: only its New rows.
    # With one (the UI export, complete decision set), the plan's automatic result
    # is combined with those decisions exactly as the review page displayed them,
    # and the recheck against a fresh backup replaces the separate resolve step.
    def apply(plan, decision_file = nil)
      with_lock do
        # Operational settings (timeouts, backups, app name) may change between review and apply.
        changed = PLAN_CONFIG_KEYS.reject { |k| plan.fetch("config")[k] == @config[k] }
        raise Error, "Configuration changed (#{changed.join(', ')}); regenerate plan" unless changed.empty?
        plan.fetch("sources").each do |source|
          raise Error, "Statement changed; regenerate plan" unless Digest::SHA256.file(source.fetch("path")).hexdigest == source.fetch("sha256")
        end
        state = ledger
        decision_file ||= { "decisions" => plan.fetch("decisions"), "category_overrides" => plan["category_overrides"] || {}, "merchant_rules" => plan["merchant_rules"] || {}, "plan" => true }
        decisions = decision_file.fetch("decisions")
        overrides = MoneyWizImport.validate_overrides(decision_file.fetch("category_overrides"))
        rules = MoneyWizImport.validate_rules(decision_file.fetch("merchant_rules"))
        unknown = (decisions.keys | overrides.keys) - plan.fetch("entries").map { |e| e["id"] }
        raise Error, "Decisions contain #{unknown.size} unknown transaction IDs; use the matching plan" unless unknown.empty?
        planner_options = { decisions: decisions, categories: overrides, rules: rules }
        require_running_app if plan.fetch("entries").any? { |e| e["status"] == "new" } || decisions.any? { |_, d| d["action"] == "new" }
        retained = @snapshotter.call
        Snapshot.prune(File.dirname(retained), keep: @config.fetch("keep_backups", 1))
        reference = Reference.new(retained)
        bank = CLI.load_bank(plan.fetch("sources").map { |s| s.fetch("path") })
        current = Planner.new(bank, reference, @config, ledger: state, **planner_options).build
        # Rows the reviewer saw as New: an explicit "new" decision, or the automatic
        # proposal for rows without one. A removed plan decision falls back to the
        # classification the page shows after Undo.
        shown = plan.fetch("entries").select do |e|
          if decision_file["plan"] then e["status"] == "new"
          elsif decisions.key?(e["id"]) then decisions[e["id"]]["action"] == "new"
          elsif plan.fetch("decisions").key?(e["id"]) then e["base_status"] == "new"
          else e["status"] == "new"
          end
        end.map { |e| e["id"] }
        # The payload the reviewer approved: plan rows when applying a plan as is,
        # otherwise this run's own recheck, since decisions can change categories.
        baseline = decision_file["plan"] ? plan.fetch("entries") : current
        intended = baseline.select { |e| shown.include?(e["id"]) && e["status"] == "new" }.to_h { |e| [e["id"], e] }
        # Persist all known matches before the first external side effect.
        current.each do |entry|
          previous = state[entry["id"]]
          next if previous && previous["status"] != "dispatching"
          if entry["status"] == "existing" && entry["match_gid"]
            matched = reference.transactions.find { |t| t["gid"] == entry.fetch("match_gid") }
            status = previous ? "imported" : "matched"
            state[entry["id"]] = { "status" => status, "gid" => entry.fetch("match_gid"), "bank_cents" => entry["cents"], "matched_cents" => matched.fetch("cents") }
          elsif entry["status"] == "skip"
            state[entry["id"]] = { "status" => "skipped" }
          end
        end
        # Remember both "always" and declined merchant category answers.
        save(state, merchant_rules.merge(rules))
        count = 0
        # The newest snapshot: the retained one until a save is verified, then the
        # copy that verified it. Reusing it avoids a second 130 MB copy per entry.
        latest = retained
        current.each do |entry|
          next unless shown.include?(entry["id"])
          next if %w[existing skip].include?(entry["status"])
          # Reconcile again immediately before each URL against a snapshot taken
          # after every transaction saved earlier in this run.
          fresh = Reference.new(latest)
          entry = Planner.new(bank, fresh, @config, ledger: state, **planner_options).build.find { |e| e["id"] == entry["id"] }
          if entry["status"] == "existing"
            # Reconciled since the plan was written. A row already recorded as
            # imported keeps that stronger fact, and one without a linked
            # transaction has nothing new to remember.
            if entry["match_gid"] && state.dig(entry["id"], "status") != "imported"
              state[entry["id"]] = { "status" => "matched", "gid" => entry.fetch("match_gid") }
              save(state)
            end
            next
          end
          raise Error, "Transaction now requires review: #{entry['id']}; regenerate plan" unless entry["status"] == "new" && intended.key?(entry["id"])
          raise Error, "Plan payload changed; regenerate plan" unless MoneyWizImport.url(entry) == MoneyWizImport.url(intended.fetch(entry["id"]))
          # Reserve durably BEFORE opening. Any crash or timeout is unresolved,
          # never a license to retry a potentially successful URL invocation.
          state[entry["id"]] = { "status" => "dispatching", "at" => Time.now.utc.iso8601 }
          save(state)
          @opener.call(MoneyWizImport.url(entry))
          # A record sent without a marker cannot be picked out of the backup, so it
          # is recorded as imported without a GID rather than searched for. The row
          # is never proposed again; reconcile the app record by eye.
          unless MoneyWizImport.memo(entry)
            state[entry["id"]] = { "status" => "imported" }
            save(state)
            count += 1
            puts "Sent #{count}/#{shown.size}: #{entry['occurred'][0, 10]} #{MoneyWizImport.money(entry['cents'])} #{entry['currency']} (unmarked, not verified)"
            next
          end
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @config.fetch("verification_seconds", 60)
          verified = nil
          loop do
            path = @snapshotter.call
            begin
              matches = Reference.new(path).marker(entry["id"])
              if matches.size == 1
                t = matches.first
                verified = t if t["account"] == entry["account"] && t["currency"] == entry["currency"] && t["cents"] == entry["cents"] && t["date"] == entry["occurred"][0, 10] && (!entry["category"] || t["category"] == entry["category"])
              end
            rescue StandardError
              File.delete(path) if File.exist?(path)
              raise
            end
            if verified
              # Keep the pre-import backup; this copy is the reference for the next entry.
              File.delete(latest) if latest != retained && File.exist?(latest)
              latest = path
              break
            end
            File.delete(path) if File.exist?(path)
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            sleep 1
          end
          raise Error, "Save unconfirmed for #{entry['id']}. Stopped; reservation retained. Re-plan to reconcile, do not delete the ledger." unless verified
          state[entry["id"]] = { "status" => "imported", "gid" => verified.fetch("gid") }
          save(state)
          count += 1
          puts "Verified #{count}/#{shown.size}: #{entry['occurred'][0, 10]} #{MoneyWizImport.money(entry['cents'])} #{entry['currency']}"
        end
        puts "Imported and verified #{count} transactions."
      ensure
        # Verification copies are temporary; only the pre-import backup stays.
        File.delete(latest) if latest && latest != retained && File.exist?(latest)
      end
    end
  end

  class CLI
    def self.render_review(plan, plan_path)
      payload = plan.merge("plan_path" => File.expand_path(plan_path), "project_path" => ROOT,
                           "downloads_path" => File.join(Dir.home, "Downloads"))
      json = JSON.generate(payload).gsub("&", '\\u0026').gsub("<", '\\u003c').gsub(">", '\\u003e').gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
      html_path = File.expand_path(plan_path).sub(/\.json\z/, "") + ".html"
      File.write(html_path, File.read(File.join(ROOT, "review.html")).sub('/*__PLAN__*/null') { json }, mode: "w", perm: 0o600)
      html_path
    end

    def self.read_decisions(path, sources)
      read_decision_file(path, sources).fetch("decisions")
    end

    # Returns {"decisions", "category_overrides", "merchant_rules"}; raw ID-to-decision maps are accepted too.
    def self.read_decision_file(path, sources)
      data = JSON.parse(File.read(path))
      overrides, rules = {}, {}
      if data.is_a?(Hash) && data["type"] == "moneywiz-decisions"
        expected = sources.map { |s| s.fetch("sha256") }.uniq.sort
        raise Error, "Decisions belong to different statements" unless data["version"] == 1 && data["source_hashes"]&.uniq&.sort == expected
        overrides = MoneyWizImport.validate_overrides(data["category_overrides"] || {})
        rules = MoneyWizImport.validate_rules(data["merchant_rules"] || {})
        data = data.fetch("decisions")
      end
      raise Error, "Expected an object mapping transaction IDs to decisions" unless data.is_a?(Hash)
      data.each do |id, decision|
        raise Error, "Invalid decision for #{id}" unless decision.is_a?(Hash) && %w[new match skip defer].include?(decision["action"])
      end
      { "decisions" => data, "category_overrides" => overrides, "merchant_rules" => rules }
    end

    HOME_SEARCH = [File.join(Dir.home, "Documents"), File.join(Dir.home, "Downloads")].freeze
    DOWNLOADS = File.join(Dir.home, "Downloads")
    REPORT_NAME = /\AReport-(\d{4}-\d{2}-\d{2})(?: \(\d+\))?\.xlsx\z/

    # decisions.json beside the plan wins. Browsers open their save dialog in
    # Documents or Downloads, so a UI export for this exact plan found there is
    # reported as well. Anything ambiguous is left to --decisions.
    def self.find_decisions(plan, run_dir, search: HOME_SEARCH)
      beside = File.join(run_dir, "decisions.json")
      return beside if File.exist?(beside)
      return nil unless plan["id"]
      strays = search.flat_map { |dir| Dir.glob(File.join(dir, "*.json")) }.select do |path|
        File.size(path) < 5_000_000 && JSON.parse(File.read(path))["plan_id"] == plan["id"]
      rescue JSON::ParserError, Errno::EACCES
        false
      end
      return nil if strays.empty?
      raise Error, "Several decisions files belong to this plan; pass one with --decisions:\n  #{strays.join("\n  ")}" if strays.size > 1
      strays.first
    end

    # Same lookup, but a stray export is adopted into the run folder first.
    def self.locate_decisions(plan, run_dir, search: HOME_SEARCH)
      found = find_decisions(plan, run_dir, search: search)
      beside = File.join(run_dir, "decisions.json")
      return found if found.nil? || found == beside
      warn "Adopting #{found} into #{run_dir}"
      FileUtils.mv(found, beside)
      beside
    end

    # The bank names its exports Report-YYYY-MM-DD.xlsx; a browser may add " (1)"
    # to a repeated download. The newest statement date wins, then the newest file.
    def self.latest_report(directory = DOWNLOADS)
      Dir.children(directory).select { |name| name.match?(REPORT_NAME) }.map { |name| File.join(directory, name) }
         .max_by { |path| [File.basename(path)[REPORT_NAME, 1], File.mtime(path)] }
    rescue Errno::ENOENT
      nil
    end

    # Plans built from exactly this statement, newest first.
    def self.plans_for(sha256, imports: File.join(PRIVATE, "imports"))
      Dir.glob(File.join(imports, "*", "plan.json")).filter_map do |path|
        plan = JSON.parse(File.read(path))
        next unless plan["sources"]&.map { |s| s["sha256"] }&.uniq == [sha256]
        [path, plan]
      rescue JSON::ParserError
        nil
      end.sort_by { |_, plan| plan["created_at"].to_s }.reverse
    end

    def self.confirm(question)
      $stdout.print "#{question} [y/N] "
      $stdout.flush
      answer = $stdin.gets
      puts if answer.nil?
      %w[y yes].include?(answer.to_s.strip.downcase)
    end

    # No arguments: find the newest bank export in Downloads and, depending on
    # what already exists for it, offer to import it or to apply its reviewed
    # decisions. Returns the command and files to run, or nil when declined.
    def self.auto(downloads: DOWNLOADS, imports: File.join(PRIVATE, "imports"), search: HOME_SEARCH)
      report = latest_report(downloads)
      raise Error, "No Report-YYYY-MM-DD.xlsx found in #{downloads}; pass a statement path to import" unless report
      puts "Statement: #{report} (modified #{File.mtime(report).strftime('%Y-%m-%d %H:%M')})"
      plans = plans_for(Digest::SHA256.file(report).hexdigest, imports: imports)
      reviewed = plans.filter_map do |path, plan|
        decisions = find_decisions(plan, File.dirname(path), search: search)
        [path, plan, decisions] if decisions
      end.first
      if reviewed
        path, plan, decisions = reviewed
        count = read_decision_file(decisions, plan.fetch("sources")).fetch("decisions").size
        summary = plan.fetch("summary", {})
        puts "Plan: #{path} (created #{plan['created_at']}; #{summary.fetch('new', 0)} new, #{summary.fetch('review', 0)} need review)"
        puts "Decisions: #{decisions} (#{count} decisions)"
        return ["apply", [path]] if confirm("Apply this plan: create its New entries in MoneyWiz?")
        return nil
      end
      if plans.any?
        path, plan = plans.first
        puts "Plan: #{path} (created #{plan['created_at']})"
        puts "No decisions file for this plan beside it, in Documents, or in Downloads."
        return ["review", [path]] if confirm("Reopen its review page?")
        return ["import", [report]] if confirm("Start a fresh import of the statement instead?")
        return nil
      end
      puts "No plan exists for this statement yet."
      return ["import", [report]] if confirm("Import it and open the review page?")
      nil
    end

    def self.sources(paths)
      paths.map { |p| { "path" => File.expand_path(p), "sha256" => Digest::SHA256.file(p).hexdigest } }
    end

    def self.open_review(path)
      raise Error, "Could not open review page: #{path}" unless system("/usr/bin/open", path)
    end

    def self.load_bank(paths)
      # Identical overlapping exports contribute max multiplicity, not a union
      # by filename and not a set that silently drops repeated purchases.
      paths.flat_map { |path| Statement.new(path).transactions }.group_by { |t| t["id"] }.map do |_, copies|
        copies.max_by { |t| t["indistinguishable_count"] }
      end.sort_by { |t| [t["occurred"], t["id"]] }
    end

    def self.run(argv)
      File.umask(0o077)
      options = { config: File.join(ROOT, "config.json") }
      parser = OptionParser.new do |o|
        o.banner = <<~HELP
          Usage: moneywiz_import [COMMAND] [files] [options]

          (no command)            Find the newest Report-YYYY-MM-DD.xlsx in ~/Downloads, then ask before
                                  importing it, or before applying it once its decisions file was saved
          import XLSX [...]       Plan in a new private/imports folder and open the review UI; no app writes
          plan XLSX [...]         Generate JSON, CSV and HTML; no app writes
          review [PLAN.json]      Open an existing plan as a static review page; no database access
          apply PLAN.json         Recheck a fresh backup, create reviewed new entries, persist matches/skips, verify saves
          resolve PLAN.json       Optional preview: the same recheck with saved decisions, written as resolved.*; no app writes
          release ID              Clear a stuck "dispatching" reservation after confirming MoneyWiz has no such record
          accounts                List account names, currencies, IDs and archive state from a backup

          apply reads decisions.json beside the plan when present; --decisions FILE overrides it.
          resolve requires --decisions FILE. review defaults to private/plan.json.
          import defaults to a new private/imports/<run>/plan.json; plan defaults to private/plan.json.
          resolve defaults to resolved.json beside its input plan. apply requires an explicit plan.
        HELP
        o.on("--config PATH") { |v| options[:config] = v }
        o.on("--snapshot PATH", "import/plan/resolve/accounts: use an existing backup (offline planning)") { |v| options[:snapshot] = v }
        o.on("--decisions PATH", "import/plan/resolve/apply: load raw or UI-exported decisions JSON") { |v| options[:decisions] = v }
        o.on("--out PATH", "import/plan/resolve: output plan.json; CSV/HTML use the same stem") { |v| options[:out] = v }
        o.on("--[no-]open", "Open the review page (default for import/review)") { |v| options[:open] = v }
        o.on("-h", "--help") { puts o; return }
      end
      parser.parse!(argv)
      command = argv.shift
      if command.nil? || command == "auto"
        raise Error, "The automatic flow takes no files; pass a command to use #{argv.first}" unless argv.empty?
        raise Error, "The automatic flow takes no --out, --decisions, or --snapshot" if options[:out] || options[:decisions] || options[:snapshot]
        command, argv = auto
        return unless command
      end
      raise Error, parser.to_s unless %w[import plan review resolve apply release accounts].include?(command)
      if %w[apply release review accounts].include?(command) && options[:out] || %w[release review accounts].include?(command) && options[:decisions]
        raise Error, "--out applies only to import, plan, and resolve; --decisions is not applicable to #{command}"
      end
      if command == "review"
        raise Error, "review accepts at most one plan file" if argv.size > 1
        raise Error, "review uses the saved plan; --snapshot is not applicable" if options[:snapshot]
        path = argv.first || File.join(PRIVATE, "plan.json")
        html = render_review(JSON.parse(File.read(path)), path)
        puts "Review: #{html}"
        open_review(html) unless options[:open] == false
        return
      end
      config = JSON.parse(File.read(options[:config]))
      MoneyWizImport.validate_payees(config.fetch("payees", {}))
      ENV["TZ"] = config.fetch("timezone")
      runner = Runner.new(config)
      if command == "release"
        raise Error, "release requires exactly one transaction ID" unless argv.size == 1
        raise Error, "release always takes a fresh snapshot" if options[:snapshot]
        runner.release(argv.first)
        return
      end
      if command == "apply"
        raise Error, "apply requires exactly one plan file" unless argv.size == 1
        raise Error, "apply always takes fresh snapshots" if options[:snapshot]
        plan_path = File.expand_path(argv.first)
        plan = JSON.parse(File.read(plan_path))
        # The review page saves decisions.json beside plan.json; --decisions overrides.
        decisions_path = options[:decisions] || locate_decisions(plan, File.dirname(plan_path))
        decision_file = nil
        if decisions_path
          decision_file = read_decision_file(decisions_path, plan.fetch("sources"))
          puts "Decisions: #{File.expand_path(decisions_path)} (#{decision_file.fetch('decisions').size} decisions)"
        end
        runner.apply(plan, decision_file)
        return
      end
      raise Error, "accounts takes no files" if command == "accounts" && !argv.empty?
      raise Error, "#{command} requires at least one bank statement" if %w[import plan].include?(command) && argv.empty?
      previous = nil
      if command == "resolve"
        raise Error, "resolve requires one plan and --decisions FILE" unless argv.size == 1 && options[:decisions]
        original_path = File.expand_path(argv.first)
        previous = JSON.parse(File.read(original_path))
        previous.fetch("sources").each do |source|
          raise Error, "Statement changed; start a new import" unless Digest::SHA256.file(source.fetch("path")).hexdigest == source.fetch("sha256")
        end
        options[:out] ||= File.join(File.dirname(original_path), "resolved.json")
        argv = previous.fetch("sources").map { |source| source.fetch("path") }
      end
      snapshot = options[:snapshot] || Snapshot.take(config.fetch("database")).tap { |path| Snapshot.prune(File.dirname(path), keep: config.fetch("keep_backups", 1)) }
      reference = Reference.new(snapshot)
      if command == "accounts"
        puts JSON.pretty_generate(reference.accounts)
        return
      end
      source_files = sources(argv)
      decision_file = options[:decisions] ? read_decision_file(options[:decisions], source_files) : { "decisions" => {}, "category_overrides" => {}, "merchant_rules" => {} }
      decisions, overrides = decision_file.fetch("decisions"), decision_file.fetch("category_overrides")
      # Rules saved by earlier applies, updated by answers in this decisions file.
      rules = runner.merchant_rules.merge(decision_file.fetch("merchant_rules"))
      # UI files contain the complete decision set, including removals (undo).
      bank = load_bank(argv)
      unknown = (decisions.keys | overrides.keys) - bank.map { |e| e["id"] }
      raise Error, "Decisions contain #{unknown.size} unknown transaction IDs; use the matching plan" unless unknown.empty?
      planner = Planner.new(bank, reference, config, ledger: runner.ledger, decisions: decisions, categories: overrides, rules: rules)
      entries = planner.build
      plan = { "version" => 1, "id" => SecureRandom.hex(16), "created_at" => Time.now.utc.iso8601, "snapshot" => File.expand_path(snapshot),
               "sources" => source_files, "categories" => reference.category_paths.values.uniq.sort,
               "config_path" => File.expand_path(options[:config]),
               "config" => config, "decisions" => decisions, "category_overrides" => overrides, "merchant_rules" => rules,
               "learned_merchants" => planner.aliases,
               "summary" => entries.group_by { |e| e["status"] }.transform_values(&:size), "entries" => entries }
      options[:out] ||= command == "import" ? File.join(PRIVATE, "imports", "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{plan['id'][0, 6]}", "plan.json") : File.join(PRIVATE, "plan.json")
      raise Error, "--out must end in .json" unless options[:out].end_with?(".json")
      MoneyWizImport.write_json(options[:out], plan)
      csv_path = options[:out].sub(/\.json\z/, "") + ".csv"
      CSV.open(csv_path, "w", write_headers: true, headers: %w[id status occurred posted account currency amount payee category reason match_gid candidates description]) do |csv|
        entries.each do |e|
          csv << [e["id"], e["status"], e["occurred"], e["posted"], e["account"], e["currency"], MoneyWizImport.money(e["cents"]), e["payee"], e["category"], e["reason"], e["match_gid"], e["candidates"].map { |t| "#{t['gid']} | #{t['date']} | #{MoneyWizImport.money(t['cents'])} | #{t['description']}" }.join(" ; "), e["description"]]
        end
      end
      puts JSON.pretty_generate(plan["summary"])
      html = render_review(plan, options[:out])
      puts "Plan: #{File.expand_path(options[:out])}\nCSV: #{File.expand_path(csv_path)}\nReview UI: #{html}\nNo MoneyWiz transactions were created."
      open_review(html) if options[:open] == true || command == "import" && options[:open] != false
    rescue Error, OptionParser::ParseError, JSON::ParserError, Errno::ENOENT, KeyError => e
      warn "Error: #{e.message}"
      exit 1
    end
  end
end

MoneyWizImport::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
