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
require_relative "internal/r2_storage"
require_relative "slot"

class Publisher
  PROGRAM_NAME = "宮舞モカの技術ニュース"

  # Workers static assets として配信するオブジェクト。これ以外は R2 に置く。
  SITE_OBJECTS = ["index.html", "feed.xml", "manifest.json"].freeze

  # 台帳。audio プレフィックスの外に置き、公開されないようにする。
  ARCHIVES_OBJECT = "archives.csv"

  def initialize(bucket: default_bucket, date: Date.today, title: nil, storage: nil)
    @bucket = bucket
    @date   = date
    @title  = title || "#{PROGRAM_NAME} #{date.strftime('%Y-%m-%d')}"
    @storage = storage
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
    rows = update_archives(filename, used_news)
    deploy_site(rows)

    puts "done: #{public_url('index.html')}"
  end

  def republish_ui
    rows = fetch_existing_archives
    abort("archives.csv does not exist yet (nothing published)") if rows.empty?

    deploy_site(rows)

    puts "done (UI only): #{public_url('index.html')}"
  end

  def object_exists?(object)
    storage.exist?(object)
  end

  def clean_archive
    count = storage.delete_prefix("#{Internal::R2Storage::ARCHIVE_PREFIX}/")

    puts "done: cleaned #{count} object(s) under #{Internal::R2Storage::ARCHIVE_PREFIX}/"
  end

  private

  def public_base = Config.cloudflare.public_base
  def default_bucket = Config.cloudflare.bucket
  def retention_episodes = Config.gcs.retention_episodes
  def cover_image = Config.assets.cover_image
  def icon_image = Config.assets.icon_image
  def audio_prefix = Config.cloudflare.audio_prefix

  def storage
    @storage ||= Internal::R2Storage.new(
      bucket: @bucket,
      account_id: Config.cloudflare.account_id,
      audio_prefix: audio_prefix
    )
  end

  # static assets 配信のものはドメイン直下、それ以外（mp3 とその兄弟ファイル）は
  # audio プレフィックス配下を指す。再生ページの JS が mp3 URL の拡張子だけを
  # 差し替えて .used.html / .transcript.txt を引くため、両者は同じ階層に並ぶ。
  def public_url(object)
    return site_url(object) if SITE_OBJECTS.include?(object)

    "#{public_base}/#{audio_prefix}/#{object}"
  end

  def site_url(object) = "#{public_base}/#{object}"

  def upload_content(object, content, content_type:, cache_control: nil)
    storage.put(storage.audio_key(object), content,
      content_type: content_type, cache_control: cache_control)
  end

  # --- mp3 ---------------------------------------------------------------

  def upload_mp3(local_path, filename)
    abort("mp3 not found: #{local_path}") unless File.exist?(local_path)
    storage.put_file(storage.audio_key(filename), local_path,
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
    storage.put_file(storage.audio_key(object), local_path,
      content_type: "text/plain; charset=utf-8")
  end

  # --- archives.csv ------------------------------------------------------

  def update_archives(filename, used_news = "")
    rows = fetch_existing_archives
    previous = rows.find { |r| r[1] == filename }
    rows.reject! { |r| r[1] == filename }
    rows << [date_for(filename), filename, @title, used_news,
      updated_at_for(previous, used_news)]
    rows.sort_by! { |r| [r[0], r[4].to_s] }
    rows.reverse!

    expired_rows = rows.drop(retention_episodes)
    rows = rows.first(retention_episodes)
    expired_rows.each { |r| archive_episode_files(r[1]) }

    csv = CSV.generate { |out| rows.each { |r| out << r } }
    storage.put(ARCHIVES_OBJECT, csv, content_type: "text/csv")

    rows
  end

  def updated_at_for(previous, used_news)
    return now_rfc3339 unless previous
    return now_rfc3339 unless previous[2] == @title && previous[3].to_s == used_news.to_s

    prior = previous[4].to_s
    prior.empty? ? now_rfc3339 : prior
  end

  # 退避先は audio プレフィックスの外（archived/）。中に置くと Worker が R2 から
  # 配信し続け、retention を超えた回が公開されたままになる。
  def archive_episode_files(filename)
    used_txt_object = filename.sub(/\.mp3\z/, ".used.txt")
    objects = self.class.episode_object_names(filename) + [self.class.used_news_html_object(used_txt_object)]
    objects.each do |object|
      storage.move(storage.audio_key(object), storage.archive_key(object))
    rescue StandardError => e
      warn "archive skipped: #{e.message}"
    end
  end

  def fetch_existing_archives
    return [] unless archives_exist?

    CSV.parse(storage.get(ARCHIVES_OBJECT))
  rescue Internal::R2Storage::Missing
    abort("failed to fetch existing archives.csv (aborting to avoid overwriting the ledger)")
  end

  def archives_exist?
    storage.exist?(ARCHIVES_OBJECT)
  end

  # --- Workers static assets へのデプロイ ---------------------------------

  # Hosting のデプロイはバージョン単位で、ステージングに無いものは消える。
  # そのため画像も含めた全ファイルを毎回書き出してから 1 回だけ deploy する。
  def deploy_site(rows)
    Dir.mktmpdir("miyamai_site") do |dir|
      File.write(File.join(dir, "index.html"), render_html(rows))
      File.write(File.join(dir, "feed.xml"), render_feed(rows))
      File.write(File.join(dir, "manifest.json"), render_manifest)
      stage_static_assets(dir)
      write_headers(dir)
      wrangler_deploy(dir)
    end
  end

  def stage_static_assets(dir)
    [icon_image, cover_image].each do |name|
      abort("asset not found: #{name} (needed for the static assets deploy)") unless File.exist?(name)
      FileUtils.cp(name, File.join(dir, File.basename(name)))
    end
  end

  # feed.xml の Content-Type は拡張子ベースだと application/xml 系になるため
  # _headers で上書きする。audio プレフィックス配下（Worker が返す経路）には
  # _headers が適用されないので、そちらは Worker 側でヘッダーを付ける。
  def write_headers(dir)
    File.write(File.join(dir, "_headers"), <<~HEADERS)
      /index.html
        Cache-Control: public, max-age=300
      /feed.xml
        Cache-Control: public, max-age=300
        Content-Type: application/atom+xml; charset=utf-8
    HEADERS
  end

  def wrangler_deploy(dir)
    args = ["deploy", "--assets", dir]
    system("wrangler", *args) ||
      abort("wrangler deploy failed: #{["wrangler", *args].join(' ')}")
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
      icon_url: site_url(File.basename(icon_image)),
      cover_url: site_url(File.basename(cover_image)),
      description: "#{date_with_slot(current[0], current[1])} — #{current[2]}",
      og_title: PROGRAM_NAME,
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
      entry_id: public_url(fname),
      updated: feed_datetime(date, updated_at),
      content: used_news.strip.empty? ? "" : h(used_news_html(used_news))).chomp
  end

  def used_news_html(used_news)
    result = UsedNewsMarkdown.render(used_news)
    result.ok ? result.html : fallback_used_news_html(used_news)
  end

  def fallback_used_news_html(used_news)
    h(used_news)
      .gsub(%r{https?://[^\s&]+}) { |url| %(<a href="#{url}">#{url}</a>) }
      .gsub("\n", "<br>\n")
  end

  # --- manifest.json (PWA) -----------------------------------------------

  def render_manifest
    TemplateRenderer.render("manifest.json", self, icon_url: site_url(File.basename(icon_image)))
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

  def date_for(filename)
    m = filename.match(/(\d{4})(\d{2})(\d{2})/)
    m ? "#{m[1]}-#{m[2]}-#{m[3]}" : @date.to_s
  end

  def h(str)
    CGI.escapeHTML(str.to_s)
  end
end
