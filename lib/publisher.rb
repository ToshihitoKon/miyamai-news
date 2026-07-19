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
require_relative "slot"

class Publisher
  # サイト全体を指す固定の番組名。archives.csv の title 列（回ごとに日付が付く）とは別物。
  # og:title/twitter:title/manifest.json の name はこちらを使う。
  PROGRAM_NAME = "宮舞モカの技術ニュース"

  # ページ/フィードのマークアップは templates/*.erb。埋め込み変数は
  # render_html / render_feed / render_feed_entry のローカル変数を binding 経由で
  # 参照する。値の HTML エスケープは呼び出し側の h() で行い、テンプレートでは素通しする。

  def initialize(bucket: default_bucket, date: Date.today, title: nil)
    @bucket = bucket
    @date   = date
    # archives.csv/feed エントリ用の回ごとのタイトル。PROGRAM_NAME とは別物。
    @title  = title || "#{PROGRAM_NAME} #{date.strftime('%Y-%m-%d')}"
  end

  # 1回のエピソードを構成するファイルの拡張子。mp3 のファイル名からの置換規則を
  # 1箇所にまとめる。
  EPISODE_FILE_EXTENSIONS = [".mp3", ".used.txt", ".transcript.txt"].freeze

  # mp3 のファイル名から、同じ回に属する全ファイル名(mp3 自身を含む)を返す。
  def self.episode_object_names(mp3_filename)
    EPISODE_FILE_EXTENSIONS.map { |ext| mp3_filename.sub(/\.mp3\z/, ext) }
  end

  # GCS 上のオブジェクト名は、渡された mp3 のファイル名をそのまま使う
  # （例: miyamai_news_20260710_afternoon.mp3）。日付から組み立て直すと
  # slot が落ちて朝昼夜深夜が同名で上書きし合うため、呼び出し側のファイル名を正とする。
  def run(mp3_path, used_txt_path = nil, transcript_txt_path = nil)
    filename = File.basename(mp3_path)
    _mp3_object, used_object, transcript_object = self.class.episode_object_names(filename)

    upload_mp3(mp3_path, filename)
    upload_used_news(used_txt_path, used_object) if used_txt_path
    upload_transcript(transcript_txt_path, transcript_object) if transcript_txt_path
    used_news = used_txt_path && File.exist?(used_txt_path) ? File.read(used_txt_path) : ""
    rows = update_archives(filename, used_news)
    write_index(rows)
    write_feed(rows)
    write_manifest

    puts "done: #{public_url('index.html')}"
  end

  # 既存 archives.csv から index.html/manifest.json だけを再生成する。
  # mp3/used.txt/archives.csv/feed.xml には一切触れない（feed.xml の更新原則の例外。
  # CLAUDE.md 参照）。
  def republish_ui
    rows = fetch_existing_archives
    abort("archives.csv does not exist yet (nothing published)") if rows.empty?

    write_index(rows)
    write_manifest

    puts "done (UI only): #{public_url('index.html')}"
  end

  # 指定オブジェクトが GCS に存在するか。「存在しない」と「確認に失敗した」を
  # 区別する（誤って false 扱いすると台帳を全消失させかねないため。CLAUDE.md 参照）。
  def object_exists?(object)
    _out, err, status = Open3.capture3("gcloud", "storage", "ls", "gs://#{@bucket}/#{object}")
    return true if status.success?
    # gcloud storage ls は「オブジェクトが無い」場合もこの exit code 1 を返すため、
    # メッセージ内容で判定する。
    return false if err.include?("matched no objects")

    raise "gcloud storage ls failed (not a \"no objects\" result, treating as a transient " \
      "failure to avoid mistaking it for absence): #{Internal::CommandError.tail(err)}"
  rescue Errno::ENOENT => e
    raise "gcloud not found: #{e.message}"
  end

  # archived/ プレフィックス配下を実削除する。publish 時の隔離とは独立して、
  # 明示的に呼ばれたときだけ動く。空なら gcloud のエラーを「削除対象なし」として無視する。
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

  # archives.csv で保持するエピソード数の上限。超えた古い回は archived/ へ退避する。
  def retention_episodes = Config.gcs.retention_episodes

  # 横長バナー画像（Slack のリンクプレビュー・再生ページ用。事前アップロード前提。
  # CLAUDE.md 参照）。
  def cover_image = Config.assets.cover_image

  # PWA 用の正方形アイコン（manifest.json 用。事前アップロード前提）。
  def icon_image = Config.assets.icon_image

  def public_url(object)
    "#{public_base}/#{@bucket}/#{object}"
  end

  # 生成した文字列を一時ファイル経由で GCS の object にアップロードする。
  # index.html / feed.xml / manifest.json / archives.csv の書き出しはすべてこの形。
  # Tempfile.create のブロックを抜けると一時ファイルは自動削除される。
  def upload_content(object, content, content_type:, cache_control: nil)
    Tempfile.create("miyamai") do |f|
      f.write(content)
      f.flush
      args = ["cp", "--content-type=#{content_type}"]
      args << "--cache-control=#{cache_control}" if cache_control
      gcloud_storage(*args, f.path, "gs://#{@bucket}/#{object}")
    end
  end

  # gcloud を配列引数で直接起動する（シェルを介さない）。publish 途中の失敗は
  # 公開物を中途半端にしないよう即 abort する。
  def gcloud_storage(*args)
    system("gcloud", "storage", *args) ||
      abort("gcloud storage failed: #{["gcloud", "storage", *args].join(' ')}")
  end

  # archived/ への退避専用。gcloud_storage と違い raise する（呼び出し元の
  # archive_episode_files が rescue して、退避に失敗した回だけスキップし publish は続ける）。
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
  # その回で使用したニュース一覧(AI 生成テキスト)。音声と対にした名前で置く。
  # 中身は解釈せず、再生ページ側でそのまま表示する(URL のみリンク化)。

  def upload_used_news(local_path, object)
    abort("used news not found: #{local_path}") unless File.exist?(local_path)
    gcloud_storage(
      "cp",
      "--content-type=text/plain; charset=utf-8",
      local_path, "gs://#{@bucket}/#{object}"
    )
  end

  # --- transcript ----------------------------------------------------------
  # 読み仮名化前の人間可読な原稿(台本)。公開ページでは「文字起こし」として提示する。
  # archives.csv/feed.xml には含めず、再生ページ側が mp3 URL から直接 fetch する
  # UI 専用の付随ファイル。

  def upload_transcript(local_path, object)
    abort("transcript not found: #{local_path}") unless File.exist?(local_path)
    gcloud_storage(
      "cp",
      "--content-type=text/plain; charset=utf-8",
      local_path, "gs://#{@bucket}/#{object}"
    )
  end

  # --- archives.csv ------------------------------------------------------
  # 列: date, filename, title, used_news, updated_at(RFC3339 UTC)。降順(新しい順)で
  # 保持し、同一 filename は上書きする。4列目/5列目を持たない過去の行は
  # used_news 空/updated_at 空(date の 00:00:00Z にフォールバック)として扱う。
  # retention_episodes を超えた古い回は台帳から外し archived/ へ退避する
  # （実削除はしない。CLAUDE.md 参照）。

  def update_archives(filename, used_news = "")
    rows = fetch_existing_archives
    rows.reject! { |r| r[1] == filename }
    rows << [date_for(filename), filename, @title, used_news, now_rfc3339]
    # 日付を第1キー、生成時刻を第2キーに新しい順で並べる。
    rows.sort_by! { |r| [r[0], r[4].to_s] }
    rows.reverse!

    expired_rows = rows.drop(retention_episodes)
    rows = rows.first(retention_episodes)
    expired_rows.each { |r| archive_episode_files(r[1]) }

    csv = CSV.generate { |out| rows.each { |r| out << r } }
    upload_content("archives.csv", csv, content_type: "text/csv")

    rows
  end

  # 保持件数を超えた回の実ファイルを archived/ へ退避する。used.txt/transcript.txt は
  # 無い回もあるので、個別の移動失敗は警告に留めて処理を継続する。
  def archive_episode_files(filename)
    self.class.episode_object_names(filename).each do |object|
      gcloud_storage_mv(object)
    rescue StandardError => e
      warn "archive skipped: #{e.message}"
    end
  end

  # 既存 archives.csv を取得して行配列で返す。オブジェクトが無い場合のみ空配列で
  # 開始し、取得失敗（ネットワーク障害等）は abort する（object_exists? 参照）。
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

    current = rows.first # 最新（降順）
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
  # archives.csv の全エピソードを新しい順のエントリにした Atom フィード。content には
  # used_news を URL リンク化した HTML を入れる（無い過去分は空）。

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
      updated: feed_datetime(rows.first[0], rows.first[4]), # 最新（降順）
      entries:)
  end

  def render_feed_entry(date, fname, title, used_news, updated_at)
    # 同一日に複数回ある場合、entry の title が重複しないよう slot を添える。
    label = slot_label(fname)
    title = "#{title}（#{label}）" unless label.empty?

    TemplateRenderer.render("feed_entry.xml", self,
      title:,
      # link は読者のクリック先なので再生ページ(index.html)にする。
      entry_url: public_url("index.html"),
      # id はエントリの一意識別子。回ごとに一意な mp3 URL のままにする
      # （全エントリを同じ index.html にすると RSS リーダーが新着を区別できない）。
      entry_id: public_url(fname),
      updated: feed_datetime(date, updated_at),
      # content type="html" はXMLデコード後にHTMLとして解釈されるため、組み立てた
      # HTML 片をそのまま埋めるとタグとして解釈される。h() でもう一段エスケープする。
      content: used_news.strip.empty? ? "" : h(used_news_html(used_news))).chomp
  end

  # used_news を content type="html" 向けの HTML に組み立てる。h() で丸ごとエスケープ
  # してから URL をリンク化し、最後に改行を <br> に変える（順序が逆だと生成した
  # <a> タグ自体がエスケープされてしまう）。
  def used_news_html(used_news)
    h(used_news)
      .gsub(%r{https?://[^\s&]+}) { |url| %(<a href="#{url}">#{url}</a>) }
      .gsub("\n", "<br>\n")
  end

  # --- manifest.json (PWA) -----------------------------------------------
  # ホーム画面追加(PWA)用の Web App Manifest。アイコンは正方形が必要なので
  # cover_image ではなく icon_image を使う。

  def write_manifest
    upload_content("manifest.json", render_manifest,
      content_type: "application/manifest+json; charset=utf-8")
  end

  def render_manifest
    TemplateRenderer.render("manifest.json", self, icon_url: public_url(icon_image))
  end

  # Atom の <updated> 用 RFC3339 日時。updated_at があればそれを使い、無い過去行は
  # date の 00:00:00 UTC にフォールバックする（Date#to_time はローカルタイム扱いに
  # なりずれるため、文字列から直接組み立てる）。
  def feed_datetime(date_str, updated_at = nil)
    return updated_at if updated_at && !updated_at.to_s.strip.empty?

    "#{Date.parse(date_str).strftime('%Y-%m-%d')}T00:00:00Z"
  end

  def now_rfc3339
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  # ファイル名の slot を日本語ラベルにする（表示用）。slot が無い旧ファイル名は
  # 空文字を返す（後方互換）。
  def slot_label(filename) = Slot.ja_label_from_filename(filename)

  def date_with_slot(date, filename)
    label = slot_label(filename)
    label.empty? ? date : "#{date}（#{label}）"
  end

  # ファイル名の日付部分を archives.csv 用の "YYYY-MM-DD" にする（GCS オブジェクト名と
  # 同じくファイル名を正とする）。読めないときだけ @date にフォールバックする。
  def date_for(filename)
    m = filename.match(/(\d{4})(\d{2})(\d{2})/)
    m ? "#{m[1]}-#{m[2]}-#{m[3]}" : @date.to_s
  end

  def h(str)
    CGI.escapeHTML(str.to_s)
  end
end
