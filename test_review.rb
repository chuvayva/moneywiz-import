#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "moneywiz_import"
require "minitest/autorun"
require "ferrum"
require "tmpdir"

class ReviewTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("moneywiz-review-test")
    @source = File.join(@dir, "statement.xlsx")
    File.write(@source, "synthetic statement")
    @candidate = { "gid" => "app-1", "date" => "2026-09-01", "cents" => -1250, "description" => "Groceries", "currency" => "GEL", "account" => "Solo ლ", "category" => "Groceries" }
    @plan = { "version" => 1, "id" => "test-plan", "created_at" => "2026-09-06T08:00:00Z", "snapshot" => "test.sqlite", "categories" => ["Groceries", "Cafe"],
              "config" => { "accounts" => { "GEL" => "Solo ლ" } }, "decisions" => {},
              "sources" => [{ "path" => @source, "sha256" => Digest::SHA256.file(@source).hexdigest }],
              "entries" => [entry("new-1", "new", "merchant" => "Nikora, Tbilisi"), entry("review-1", "review", "candidates" => [@candidate], "merchant" => "NIKORA , Tbilisi"),
                              entry("existing-1", "existing", "match_gid" => "other-app"),
                              entry("locked-1", "review", "decision_locked" => true),
                              entry("fx-1", "review", "kind" => "FX")] }
    @path = File.join(@dir, "plan.json")
    @html = MoneyWizImport::CLI.render_review(@plan, @path)
    @browser = Ferrum::Browser.new(browser_path: ENV.fetch("CHROME_PATH", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), headless: true, window_size: [1440, 1000], timeout: 10)
    @browser.on(:dialog) { |dialog| dialog.accept }
    @browser.go_to("file://#{@html}")
  end

  def teardown
    @browser&.quit
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def entry(id, status, extras = {})
    { "id" => id, "status" => status, "base_status" => status, "cents" => -1250, "currency" => "GEL", "account" => "Solo ლ", "payee" => id,
      "description" => "Tea & bread </script><script>window.INJECTED=true</script> C:\\bank\\2026", "occurred" => "2026-09-01 12:00:00", "posted" => "2026-09-02",
      "category" => nil, "reason" => "Synthetic reason", "row" => 2, "kind" => "Payment", "candidates" => [], "indistinguishable_count" => 1, "merchant" => "#{id} Store, Tbilisi" }.merge(extras)
  end

  def evaluate(js)
    @browser.evaluate(js)
  end

  def click(selector)
    @browser.execute("document.querySelector(#{JSON.generate(selector)}).scrollIntoView({block:'center',behavior:'instant'})")
    @browser.at_css(selector).click
  end

  def action(value)
    @browser.execute("document.getElementById('decision-action').value=#{JSON.generate(value)}; document.getElementById('decision-action').dispatchEvent(new Event('change'))")
  end

  def test_filters_search_and_script_injection_are_safe
    assert_nil evaluate("window.INJECTED")
    assert_equal 5, evaluate("document.querySelectorAll('#rows tr').length")
    click('[data-filter="new"]')
    assert_equal 1, evaluate("document.querySelectorAll('#rows tr').length")
    click('[data-filter="review"]')
    assert_equal 3, evaluate("document.querySelectorAll('#rows tr').length")
    @browser.execute("document.getElementById('search').value='fx-1'; document.getElementById('search').dispatchEvent(new Event('input'))")
    assert_equal 1, evaluate("document.querySelectorAll('#rows tr').length")
    assert_equal @plan["entries"][0]["description"], evaluate("plan.entries[0].description")
  end

  def test_defer_restores_from_localstorage_and_round_trips_to_ruby
    click('tr[data-id="new-1"] button')
    action("defer")
    click("#save-decision")
    assert_equal "review", evaluate("status(plan.entries[0])")
    @browser.refresh
    assert_equal "defer", evaluate("decisions['new-1'].action")
    data = evaluate("exportData()")
    path = File.join(@dir, "decisions.json")
    File.write(path, JSON.generate(data))
    assert_equal({ "new-1" => { "action" => "defer" } }, MoneyWizImport::CLI.read_decisions(path, @plan["sources"]))
    data["source_hashes"] = ["wrong"]
    File.write(path, JSON.generate(data))
    assert_raises(MoneyWizImport::Error) { MoneyWizImport::CLI.read_decisions(path, @plan["sources"]) }
  end

  def test_match_and_uncategorized_new_decisions
    click('tr[data-id="review-1"] button')
    action("match")
    evaluate("document.getElementById('decision-match').value='app-1'")
    click("#save-decision")
    assert_equal({ "action" => "match", "gid" => "app-1" }, evaluate("decisions['review-1']"))
    action("new")
    click("#save-decision")
    assert_equal({ "action" => "new" }, evaluate("decisions['review-1']"))
  end

  def test_locked_records_have_no_editor_and_non_purchase_saves_as_plain_new
    click('tr[data-id="locked-1"] button')
    assert_nil @browser.at_css("#decision-action")
    click('tr[data-id="fx-1"] button')
    action("new")
    assert_includes @browser.at_css("#inspector").text, "titled “FX”"
    click("#save-decision")
    assert_equal({ "action" => "new" }, evaluate("decisions['fx-1']"))
  end

  def test_download_exports_file_and_does_not_execute_commands
    @browser.downloads.set_behavior(save_path: @dir)
    click('tr[data-id="new-1"] button')
    action("skip")
    click("#save-decision")
    click("#download-top")
    path = File.join(@dir, "decisions.json")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(path)
      raise "Download missing" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    assert_equal "skip", JSON.parse(File.read(path)).dig("decisions", "new-1", "action")
    assert_equal false, evaluate("dirty()")
    assert_equal true, evaluate("document.getElementById('export-dialog').open")
  end

  def test_apply_command_defaults_to_decisions_beside_plan_and_adds_flag_elsewhere
    assert_equal "#{@dir}/decisions.json", evaluate("document.getElementById('decision-path').value")
    @browser.execute("plan.config_path=plan.project_path+'/config.json'; commands()")
    refute_includes evaluate("document.getElementById('import-command').textContent"), "--config", "the default config needs no flag"
    @browser.execute("plan.config_path='/elsewhere/other.json'; commands()")
    assert_includes evaluate("document.getElementById('import-command').textContent"), "--config '/elsewhere/other.json'"
    @browser.execute("delete plan.config_path; commands()")
    assert_equal "moneywiz_import.rb apply '#{@path}'", evaluate("document.getElementById('apply-command').textContent")
    @browser.execute("const p=document.getElementById('decision-path'); p.value='/Users/me/Downloads/decisions.json'; p.dispatchEvent(new Event('input'))")
    assert_equal "moneywiz_import.rb apply '#{@path}' --decisions '/Users/me/Downloads/decisions.json'", evaluate("document.getElementById('apply-command').textContent")
    assert_includes evaluate("document.getElementById('resolve-command').textContent"), "--decisions '/Users/me/Downloads/decisions.json'"
  end

  def test_save_picker_cancellation_keeps_dirty_state
    evaluate("window.showSaveFilePicker=async()=>{throw new DOMException('Cancelled','AbortError')}")
    click('tr[data-id="new-1"] button')
    action("defer")
    click("#save-decision")
    click("#save-top")
    assert_equal true, evaluate("dirty()")
    assert_equal false, evaluate("document.getElementById('export-dialog').open")
  end

  def test_undo_from_resolved_plan_uses_original_status
    @browser.execute("plan.decisions['new-1']={action:'skip'}; plan.entries[0].status='skip'; decisions['new-1']={action:'skip'}; render()")
    click('tr[data-id="new-1"] button')
    evaluate("document.querySelectorAll('#inspector button').forEach(b=>{if(b.textContent==='Undo decision')b.click()})")
    assert_equal "new", evaluate("status(plan.entries[0])")
    assert_nil evaluate("decisions['new-1']")
  end

  def test_bulk_selection_survives_filters_and_pages_and_skips_in_bulk
    assert_nil @browser.at_css('tr[data-id="locked-1"] input[type=checkbox]'), "locked rows must not be selectable"
    click('tr[data-id="new-1"] input[type=checkbox]')
    click('[data-filter="review"]')
    click('tr[data-id="review-1"] input[type=checkbox]')
    assert_equal "2 selected", @browser.at_css("#bulk-count").text
    # Add a second page and select a row there too.
    @browser.execute("for(let i=0;i<50;i++){plan.entries.push({...plan.entries[0],id:'extra-'+i,payee:'extra-'+i,status:'review',base_status:'review'})}; filter='all'; render()")
    click("#next")
    click('tr[data-id="extra-49"] input[type=checkbox]')
    assert_equal "3 selected", @browser.at_css("#bulk-count").text
    click('[data-bulk="skip"]')
    assert_equal %w[new-1 review-1 extra-49], evaluate("Object.keys(decisions)")
    assert_equal "skip", evaluate("decisions['extra-49'].action")
    assert_equal true, evaluate("document.getElementById('bulk').hidden")
    assert_equal 3, evaluate("plan.entries.filter(e=>status(e)==='skip').length")
  end

  def test_bulk_select_all_matching_and_new_includes_fx_and_ignores_locked
    click('[data-filter="review"]')
    click("#check-page")
    assert_equal "2 selected", @browser.at_css("#bulk-count").text, "locked row is excluded from select-all"
    click('[data-bulk="new"]')
    assert_equal({ "action" => "new" }, evaluate("decisions['review-1']"))
    assert_equal({ "action" => "new" }, evaluate("decisions['fx-1']"), "FX rows import like purchases, uncategorized")
    assert_nil evaluate("decisions['locked-1']")
    refute_includes @browser.at_css("#message").text, "skipped"
    click('[data-filter="all"]')
    @browser.execute("document.getElementById('search').value='review'; document.getElementById('search').dispatchEvent(new Event('input'))")
    click('tr[data-id="review-1"] input[type=checkbox]')
    click('[data-bulk="undo"]')
    assert_nil evaluate("decisions['review-1']")
  end

  def set_select(id, value)
    @browser.execute("document.getElementById(#{JSON.generate(id)}).value=#{JSON.generate(value)}; document.getElementById(#{JSON.generate(id)}).dispatchEvent(new Event('change'))")
  end

  def test_category_choice_asks_once_per_merchant_and_keeps_yes_and_no_answers
    click('tr[data-id="new-1"] button')
    set_select("entry-category", "Groceries")
    assert_equal "Groceries", evaluate("overrides['new-1']")
    assert_equal true, evaluate("document.getElementById('rule-dialog').open")
    assert_equal 1, evaluate("document.querySelectorAll('#rule-list input').length")
    assert_includes @browser.at_css("#rule-list").text, "1 other row"
    click("#rule-save")
    assert_equal({ "category" => "Groceries", "always" => true }, evaluate("rules['nikora']"))
    assert_equal({ "category" => "Groceries", "source" => "rule" }, evaluate("categoryOf(plan.entries[1])"), "same merchant, different spacing/case")
    assert_includes @browser.at_css('tr[data-id="review-1"]').text, "Groceries · merchant rule"
    # Answer "no" for a different category.
    set_select("entry-category", "Cafe")
    assert_equal true, evaluate("document.getElementById('rule-dialog').open")
    @browser.execute("document.querySelector('#rule-list input').checked=false")
    click("#rule-save")
    assert_equal({ "category" => "Cafe", "always" => false }, evaluate("rules['nikora']"))
    assert_nil evaluate("categoryOf(plan.entries[1]).category")
    assert_equal "Cafe", evaluate("overrides['new-1']")
    # A different pairing asks again; the answered pairing does not.
    set_select("entry-category", "Groceries")
    assert_equal true, evaluate("document.getElementById('rule-dialog').open")
    click("#rule-later")
    set_select("entry-category", "Cafe")
    assert_equal false, evaluate("document.getElementById('rule-dialog').open")
    # Round trip through the export and Ruby, then survive a refresh.
    data = evaluate("exportData()")
    path = File.join(@dir, "decisions.json")
    File.write(path, JSON.generate(data))
    file = MoneyWizImport::CLI.read_decision_file(path, @plan["sources"])
    assert_equal({ "new-1" => "Cafe" }, file["category_overrides"])
    assert_equal false, file.dig("merchant_rules", "nikora", "always")
    @browser.refresh
    assert_equal "Cafe", evaluate("overrides['new-1']")
    assert_equal false, evaluate("rules['nikora'].always")
    # Rules card in Import details can forget a rule.
    click('[data-tab="details"]')
    assert_includes @browser.at_css("#rules-card").text, "nikora"
    click('[data-forget="nikora"]')
    assert_equal({}, evaluate("rules"))
  end

  def test_bulk_set_category_and_ask_later_saves_no_rule
    click('tr[data-id="review-1"] input[type=checkbox]')
    click('tr[data-id="fx-1"] input[type=checkbox]')
    click('tr[data-id="locked-1"] button')
    set_select("bulk-category", "Cafe")
    click('[data-bulk="category"]')
    assert_equal({ "review-1" => "Cafe", "fx-1" => "Cafe" }, evaluate("overrides"))
    assert_equal 2, evaluate("document.querySelectorAll('#rule-list input').length")
    click("#rule-later")
    assert_equal({}, evaluate("rules"))
    assert_equal true, evaluate("dirty()")
    assert_equal "Cafe", evaluate("categoryOf(plan.entries[1]).category")
    assert_includes @browser.at_css('tr[data-id="fx-1"]').text, "Cafe · chosen"
    click('tr[data-id="review-1"] button')
    action("new")
    click("#save-decision")
    assert_equal({ "action" => "new" }, evaluate("decisions['review-1']"))
    assert_equal [], evaluate("validationErrors()")
  end
end
