# frozen_string_literal: true

require "date"
require "csv"
require "json"
require "cgi"
require "tempfile"
require "open3"
require_relative "internal/config"
require_relative "internal/template_renderer"
require_relative "internal/command_error"
require_relative "internal/used_news_markdown"
require_relative "internal/used_news_formatter"
require_relative "slot"

class Publisher
  PROGRAM_NAME = "宮舞モカの技術ニュース"

  def initialize(bucket: default_bucket, date: Date.today, title: nil)
    @bucket = bucket
    @date   = date
    @title  = title || "#{PROGRAM_NAME} #{date.strftime('%Y-%m-%d')}"
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
    write_index(rows)
    write_feed(rows)
    write_manifest

    puts "done: #{public_url('index.html')}"
  end

  def republish_ui
    rows = fetch_existing_archives
    abort("archives.csv does not exist yet (nothing published)") if rows.empty?

    write_index(rows)
    write_manifest

    puts "done (UI only): #{public_url('index.html')}"
  end

  def object_exists?(object)
    _out, err, status = Open3.capture3("gcloud", "storage", "ls", "gs://#{@bucket}/#{object}")
    return true if status.success?
    return false if err.include?("matched no objects")

    raise "gcloud storage ls failed (not a \"no objects\" result, treating as a transient " \
      "failure to avoid mistaking it for absence): #{Internal::CommandError.tail(err)}"
  rescue Errno::ENOENT => e
    raise "gcloud not found: #{e.message}"
  end

  def clean_archive
    _out, err, status = Open3.capture3("gcloud", "storage", "rm", "--recursive", "gs://#{@bucket}/archived/**")
    unless status.success? || err.include?("matched no objects")
      abort("gcloud storage rm failed: #{Internal::CommandError.tail(err)}")
    end

    puts "done: cleaned gs://#{@bucket}/archived/"
  end

  private

  def public_base = Config.gcs.public_base
  def default_bucket = Config.gcs.bucket
  def retention_episodes = Config.gcs.retention_episodes
  def cover_image = Config.assets.cover_image
  def icon_image = Config.assets.icon_image

  def public_url(object)
    "#{public_base}/#{@bucket}/#{object}"
  end

  def upload_content(object, content, content_type:, cache_control: nil)
    Tempfile.create("miyamai") do |f|
      f.write(content)
      f.flush
      args = ["cp", "--content-type=#{content_type}"]
      args << "--cache-control=#{cache_control}" if cache_control
      gcloud_storage(*args, f.path, "gs://#{@bucket}/#{object}")
    end
  end

  def gcloud_storage(*args)
    system("gcloud", "storage", *args) ||
      abort("gcloud storage failed: #{["gcloud", "storage", *args].join(' ')}")
  end

  def gcloud_storage_mv(object)
    args = ["mv", "gs://#{@bucket}/#{object}", "gs://#{@bucket}/archived/#{object}"]
    system("gcloud", "storage", *args) ||
      raise("gcloud storage mv failed: #{["gcloud", "storage", *args].join(' ')}")
  end

  # --- mp3 ---------------------------------------------------------------

  def upload_mp3(local_path, filename)
    abort("mp3 not found: #{local_path}") unless File.exist?(local_path)
    gcloud_storage(
      "cp",
      "--content-type=audio/mpeg",
      "--content-disposition=inline",
      local_path, "gs://#{@bucket}/#{filename}"
    )
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
    gcloud_storage(
      "cp",
      "--content-type=text/plain; charset=utf-8",
      local_path, "gs://#{@bucket}/#{object}"
    )
  end

  # --- archives.csv ------------------------------------------------------

  def update_archives(filename, used_news = "")
    rows = fetch_existing_archives
    rows.reject! { |r| r[1] == filename }
    rows << [date_for(filename), filename, @title, used_news, now_rfc3339]
    rows.sort_by! { |r| [r[0], r[4].to_s] }
    rows.reverse!

    expired_rows = rows.drop(retention_episodes)
    rows = rows.first(retention_episodes)
    expired_rows.each { |r| archive_episode_files(r[1]) }

    csv = CSV.generate { |out| rows.each { |r| out << r } }
    upload_content("archives.csv", csv, content_type: "text/csv")

    rows
  end

  def archive_episode_files(filename)
    used_txt_object = filename.sub(/\.mp3\z/, ".used.txt")
    objects = self.class.episode_object_names(filename) + [self.class.used_news_html_object(used_txt_object)]
    objects.each do |object|
      gcloud_storage_mv(object)
    rescue StandardError => e
      warn "archive skipped: #{e.message}"
    end
  end

  def fetch_existing_archives
    return [] unless archives_exist?

    Tempfile.create("miyamai_archives") do |f|
      ok = system("gcloud", "storage", "cp", "gs://#{@bucket}/archives.csv", f.path,
        out: File::NULL, err: File::NULL)
      abort("failed to fetch existing archives.csv (aborting to avoid overwriting the ledger)") unless ok

      CSV.read(f.path)
    end
  end

  def archives_exist?
    object_exists?("archives.csv")
  end

  # --- index.html --------------------------------------------------------

  def write_index(rows)
    upload_content("index.html", render_html(rows),
      content_type: "text/html; charset=utf-8",
      cache_control: "public, max-age=300")
  end

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
      icon_url: public_url(icon_image),
      cover_url: public_url(cover_image),
      description: "#{date_with_slot(current[0], current[1])} — #{current[2]}",
      og_title: PROGRAM_NAME,
      options:)
  end

  # --- feed.xml (Atom) ---------------------------------------------------

  def write_feed(rows)
    upload_content("feed.xml", render_feed(rows),
      content_type: "application/atom+xml; charset=utf-8")
  end

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

  def write_manifest
    upload_content("manifest.json", render_manifest,
      content_type: "application/manifest+json; charset=utf-8")
  end

  def render_manifest
    TemplateRenderer.render("manifest.json", self, icon_url: public_url(icon_image))
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
