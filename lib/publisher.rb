# frozen_string_literal: true

require "date"
require "csv"
require "json"
require "cgi"
require "fileutils"
require "tmpdir"
require_relative "internal/config"
require_relative "internal/template_renderer"
require_relative "internal/used_news_markdown"
require_relative "internal/used_news_formatter"
require_relative "internal/site"
require_relative "internal/episode_notifier"
require_relative "slot"

class Publisher
  PROGRAM_NAME = "宮舞モカの技術ニュース"

  # feed 自身の <id> に使う発行日。フィードの同一性を表すので、
  # 一度決めたら変えない（変えると購読者が別フィードとして扱う）。
  FEED_ID_DATE = "2026-07-31"

  def initialize(date: Date.today, title: nil, site: nil, notifier: nil)
    @date  = date
    @title = title || "#{PROGRAM_NAME} #{date.strftime('%Y-%m-%d')}"
    @site  = site || Internal::Site.from_config
    @notifier = notifier || Internal::EpisodeNotifier.from_config
  end

  EPISODE_FILE_EXTENSIONS = [".mp3", ".used.txt", ".transcript.txt"].freeze

  def self.episode_object_names(mp3_filename)
    EPISODE_FILE_EXTENSIONS.map { |ext| mp3_filename.sub(/\.mp3\z/, ext) }
  end

  def self.used_news_html_object(used_object) = used_object.sub(/\.used\.txt\z/, ".used.html")

  def run(mp3_path, used_txt_path = nil, transcript_txt_path = nil)
    filename = File.basename(mp3_path)
    _mp3_object, used_object, transcript_object = self.class.episode_object_names(filename)

    used_news = load_and_validate_used_news(used_txt_path)

    upload_mp3(mp3_path, filename)
    if used_txt_path
      upload_used_news_content(used_news, used_object)
      upload_used_news_html(used_news, self.class.used_news_html_object(used_object))
    end
    upload_transcript(transcript_txt_path, transcript_object) if transcript_txt_path
    rows, newly_published, expired_rows, ledger_csv = build_archives(filename, used_news, used_news_given: !used_txt_path.nil?)
    deploy_site(rows)
    @site.write_ledger(ledger_csv)
    expired_rows.each { |r| archive_episode_files(r[1]) }
    if newly_published
      @notifier.notify(title: "新着ニュースが公開されました",
        body: notification_body(filename),
        url: public_url("index.html"))
    end

    puts "done: #{public_url('index.html')}"
  end

  def republish_ui
    rows = fetch_existing_archives
    abort("archives.csv does not exist yet (nothing published)") if rows.empty?

    deploy_site(rows)

    puts "done (UI only): #{public_url('index.html')}"
  end

  def object_exists?(object)
    @site.episode_file_exist?(object)
  end

  def clean_archive
    count = @site.purge_retired

    puts "done: cleaned #{count} retired object(s)"
  end

  private

  def retention_episodes = @site.retention_episodes
  def cover_image = Config.assets.cover_image
  def icon_image = Config.assets.icon_image

  def public_url(object) = @site.url_for(object)
  def site_url(object) = @site.page_url(object)
  def asset_url(name) = @site.asset_url(File.basename(name))

  def upload_content(object, content, content_type:, cache_control: nil)
    @site.write_episode_file(object, content,
      content_type: content_type, cache_control: cache_control)
  end

  # --- mp3 ---------------------------------------------------------------

  def upload_mp3(local_path, filename)
    abort("mp3 not found: #{local_path}") unless File.exist?(local_path)
    @site.upload_episode_file(filename, local_path,
      content_type: "audio/mpeg", cache_control: "public, max-age=31536000, immutable")
  end

  # --- used news ---------------------------------------------------------

  def load_and_validate_used_news(used_txt_path)
    return "" unless used_txt_path && File.exist?(used_txt_path)

    UsedNewsFormatter.ensure_valid!(File.read(used_txt_path))
  end

  def upload_used_news_content(content, object)
    upload_content(object, content, content_type: "text/plain; charset=utf-8")
  end

  def upload_used_news_html(used_news, object)
    result = UsedNewsMarkdown.render(used_news)
    return unless result.ok

    upload_content(object, result.html,
      content_type: "text/html; charset=utf-8",
      cache_control: "public, max-age=300")
  end

  # --- transcript ----------------------------------------------------------

  def upload_transcript(local_path, object)
    abort("transcript not found: #{local_path}") unless File.exist?(local_path)
    @site.upload_episode_file(object, local_path,
      content_type: "text/plain; charset=utf-8")
  end

  # --- archives.csv ------------------------------------------------------

  # 戻り値は [rows, newly_published, expired_rows, ledger_csv]。
  def build_archives(filename, used_news = "", used_news_given: true)
    rows = fetch_existing_archives
    previous = rows.find { |r| r[1] == filename }
    changed = content_changed?(previous, used_news, used_news_given: used_news_given)
    rows.reject! { |r| r[1] == filename }
    rows << [date_for(filename), filename, @title, used_news,
             updated_at_for(previous, changed:)]
    rows.sort_by! { |r| [r[0], r[4].to_s] }
    rows.reverse!

    expired_rows = rows.drop(retention_episodes)
    rows = rows.first(retention_episodes)

    csv = CSV.generate { |out| rows.each { |r| out << r } }

    [rows, changed, expired_rows, csv]
  end

  def content_changed?(previous, used_news, used_news_given:)
    return true unless previous
    return true if previous[2] != @title

    used_news_given && previous[3].to_s != used_news.to_s
  end

  def updated_at_for(previous, changed:)
    return now_rfc3339 if changed || !previous

    prior = previous[4].to_s
    prior.empty? ? now_rfc3339 : prior
  end

  def archive_episode_files(filename)
    used_txt_object = filename.sub(/\.mp3\z/, ".used.txt")
    objects = self.class.episode_object_names(filename) + [self.class.used_news_html_object(used_txt_object)]
    objects.each do |object|
      @site.retire_episode_file(object)
    rescue StandardError => e
      warn "archive skipped: #{e.message}"
    end
  end

  def fetch_existing_archives
    return [] unless archives_exist?

    CSV.parse(@site.read_ledger)
  rescue Internal::Site::LedgerMissing
    abort("failed to fetch existing archives.csv (aborting to avoid overwriting the ledger)")
  end

  def archives_exist?
    @site.ledger_exist?
  end

  # --- サイトの反映 ------------------------------------------------------

  # 反映はディレクトリ単位で、ここに無いファイルは公開サイトから消える。
  # 生成ページを毎回すべて書き出してから 1 回だけ反映する。
  def deploy_site(rows)
    Dir.mktmpdir("miyamai_site") do |dir|
      File.write(File.join(dir, "index.html"), render_html(rows))
      File.write(File.join(dir, "feed.xml"), render_feed(rows))
      File.write(File.join(dir, "manifest.json"), render_manifest)
      File.write(File.join(dir, "sw.js"), render_sw)
      @site.deploy(dir)
    rescue Internal::Site::DeployFailed => e
      abort(e.message)
    end
  end

  # --- index.html --------------------------------------------------------

  def render_html(rows)
    abort("no archives to render") if rows.empty?

    current = rows.first
    options = rows.map do |date, fname, _title, _used_news, updated_at|
      label = date_with_slot(date, fname)
      selected = fname == current[1] ? " selected" : ""
      %(<option value="#{h(public_url(fname))}" data-label="#{h(label)}" data-updated-at="#{h(feed_datetime(date, updated_at))}"#{selected}>#{h(label)}</option>)
    end.join("\n        ")

    TemplateRenderer.render("index.html", self,
      current:,
      current_url: public_url(current[1]),
      page_url: public_url("index.html"),
      feed_url: public_url("feed.xml"),
      manifest_url: public_url("manifest.json"),
      icon_url: asset_url(icon_image),
      cover_url: asset_url(cover_image),
      description: "#{date_with_slot(current[0], current[1])} — #{current[2]}",
      og_title: PROGRAM_NAME,
      web_push_public_key: Config.web_push&.vapid_public_key,
      options:)
  end

  # --- feed.xml (Atom) ---------------------------------------------------

  def render_feed(rows)
    abort("no archives to render") if rows.empty?

    entries = rows.map do |date, fname, title, used_news, updated_at|
      render_feed_entry(date, fname, title, used_news.to_s, updated_at)
    end.join("\n")

    TemplateRenderer.render("feed.xml", self,
      program_name: PROGRAM_NAME,
      feed_id: feed_id,
      feed_url: public_url("feed.xml"),
      page_url: public_url("index.html"),
      updated: feed_datetime(rows.first[0], rows.first[4]),
      entries:)
  end

  def render_feed_entry(date, fname, title, used_news, updated_at)
    label = slot_label(fname)
    title = "#{title}（#{label}）" unless label.empty?

    TemplateRenderer.render("feed_entry.xml", self,
      title:,
      entry_url: public_url("index.html"),
      entry_id: entry_id(fname),
      updated: feed_datetime(date, updated_at),
      content: used_news.strip.empty? ? "" : h(used_news_html(used_news))).chomp
  end

  def feed_id = @site.tag_uri(FEED_ID_DATE, "feed")

  def entry_id(fname) = @site.tag_uri(date_for(fname), File.basename(fname, ".mp3"))

  def used_news_html(used_news)
    result = UsedNewsMarkdown.render(used_news)
    result.ok ? result.html : fallback_used_news_html(used_news)
  end

  def fallback_used_news_html(used_news)
    h(used_news)
      .gsub(%r{https?://[^\s<]+}) { |url| %(<a href="#{url}">#{url}</a>) }
      .gsub("\n", "<br>\n")
  end

  # --- manifest.json (PWA) -----------------------------------------------

  def render_manifest
    TemplateRenderer.render("manifest.json", self, icon_url: asset_url(icon_image))
  end

  # --- sw.js (Service Worker) --------------------------------------------

  def render_sw
    TemplateRenderer.render("sw.js", self, page_url: public_url("index.html"), icon_url: asset_url(icon_image))
  end

  def feed_datetime(date_str, updated_at = nil)
    return updated_at if updated_at && !updated_at.to_s.strip.empty?

    "#{date_str}T00:00:00Z"
  end

  def now_rfc3339
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  def slot_label(filename) = Slot.ja_label_from_filename(filename)

  def date_with_slot(date, filename)
    label = slot_label(filename)
    label.empty? ? date : "#{date}（#{label}）"
  end

  def notification_body(filename)
    date = date_for(filename)
    label = slot_label(filename)
    label.empty? ? date : "#{date} #{label}"
  end

  def date_for(filename)
    m = filename.match(/(\d{4})(\d{2})(\d{2})/)
    m ? "#{m[1]}-#{m[2]}-#{m[3]}" : @date.to_s
  end

  def h(str)
    CGI.escapeHTML(str.to_s)
  end
end
