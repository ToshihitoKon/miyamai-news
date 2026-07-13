# frozen_string_literal: true

require "date"
require "csv"
require "json"
require "cgi"
require "shellwords"
require "tmpdir"
require_relative "config"
require_relative "template_renderer"

class Publisher
  PUBLIC_BASE    = Config.get("gcs.public_base")
  DEFAULT_BUCKET = Config.get("gcs.bucket")
  # サイト全体を指す固定の番組名。archives.csv の title 列（回ごとに日付が付く）とは別物。
  # og:title/twitter:title/manifest.json の name はこちらを使う。
  PROGRAM_NAME = "宮舞モカの技術ニュース"
  # 横長バナー画像。Slack のリンクプレビューと再生ページの両方で使う。
  # GCS への事前アップロードが前提（README 参照）。
  COVER_IMAGE = Config.get("assets.cover_image")
  # PWA(ホーム画面追加)用の正方形アイコン。manifest.json から参照する。
  # cover_image と同じく GCS への事前アップロードが前提（README 参照）。
  ICON_IMAGE = Config.get("assets.icon_image")

  # ページ/フィードのマークアップは templates/*.erb。埋め込み変数は
  # render_html / render_feed / render_feed_entry のローカル変数を binding 経由で
  # 参照する。値の HTML エスケープは呼び出し側の h() で行い、テンプレートでは素通しする。

  def initialize(bucket: DEFAULT_BUCKET, date: Date.today, title: nil)
    @bucket = bucket
    @date   = date
    # archives.csv/feed エントリ用の回ごとのタイトル。PROGRAM_NAME とは別物。
    @title  = title || "#{PROGRAM_NAME} #{date.strftime('%Y-%m-%d')}"
  end

  # GCS 上のオブジェクト名は、渡された mp3 のファイル名をそのまま使う
  # （例: miyamai_news_20260710_afternoon.mp3）。日付から組み立て直すと
  # slot が落ちて朝昼夜深夜が同名で上書きし合うため、呼び出し側のファイル名を正とする。
  def run(mp3_path, used_txt_path = nil)
    filename = File.basename(mp3_path)
    used_object = filename.sub(/\.mp3\z/, ".used.txt")

    upload_mp3(mp3_path, filename)
    upload_used_news(used_txt_path, used_object) if used_txt_path
    used_news = used_txt_path && File.exist?(used_txt_path) ? File.read(used_txt_path) : ""
    rows = update_archives(filename, used_news)
    write_index(rows)
    write_feed(rows)
    write_manifest

    puts "done: #{public_url('index.html')}"
  end

  # 既存 archives.csv を読み込んで index.html / manifest.json だけを再生成する。
  # mp3・used.txt・archives.csv・feed.xml には一切触れない。UI 文言だけを直したときに、
  # 新しい回を公開したとの誤解（Atom の <updated> 更新による通知）を避けつつ、
  # 表示だけ即時反映したい場合に使う。
  def republish_ui
    local_csv = File.join(Dir.tmpdir, "miyamai_archives_#{Process.pid}.csv")
    rows = fetch_existing_archives(local_csv)
    abort("archives.csv がまだ存在しません（公開実績がありません）") if rows.empty?

    write_index(rows)
    write_manifest

    puts "done (UI only): #{public_url('index.html')}"
  ensure
    File.delete(local_csv) if local_csv && File.exist?(local_csv)
  end

  # 指定オブジェクトが GCS のバケットに存在するか。
  def object_exists?(object)
    system("gcloud", "storage", "ls", "gs://#{@bucket}/#{object}",
      out: File::NULL, err: File::NULL)
  end

  private

  def public_url(object)
    "#{PUBLIC_BASE}/#{@bucket}/#{object}"
  end

  def gcloud_storage(*args)
    cmd = ["gcloud", "storage", *args].shelljoin
    system(cmd) || abort("gcloud storage failed: #{cmd}")
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

  # --- archives.csv ------------------------------------------------------
  # 列: date(YYYY-MM-DD), filename, title, used_news, updated_at(RFC3339 UTC)
  # used_news はその回で紹介したニュース一覧の全文(Atom フィードの content 用)。
  # updated_at は生成時刻。当日分を作り直すたびに更新され、Atom の <updated> に
  # 使う。これにより同じ日に再生成しても更新が進み、RSS リーダーが検知できる。
  # 4列目を持たない過去の行は used_news 空、5列目を持たない過去の行は
  # updated_at 空(date の 00:00:00Z にフォールバック)として扱う。
  # 同一 filename は上書き。1日に複数回(朝昼夜)ある場合は date が同じでも
  # filename が異なる行として共存する。降順(新しい順)で保持。

  def update_archives(filename, used_news = "")
    local_csv = File.join(Dir.tmpdir, "miyamai_archives_#{Process.pid}.csv")

    rows = fetch_existing_archives(local_csv)
    # 同じファイル名(=同じ日の同じ時間帯)の回があれば差し替える。
    # 1日に朝昼夜と複数回ある場合、date は同じでも filename が異なるので共存する。
    rows.reject! { |r| r[1] == filename }
    rows << [date_for(filename), filename, @title, used_news, now_rfc3339]
    # 日付(YYYY-MM-DD)を第1キー、生成時刻を第2キーに新しい順で並べる。
    # 同一日に複数回ある場合、生成時刻で slot の前後を安定させる。
    rows.sort_by! { |r| [r[0], r[4].to_s] }
    rows.reverse!

    CSV.open(local_csv, "w") { |csv| rows.each { |r| csv << r } }
    gcloud_storage("cp", "--content-type=text/csv", local_csv, "gs://#{@bucket}/archives.csv")

    rows
  ensure
    File.delete(local_csv) if local_csv && File.exist?(local_csv)
  end

  # 既存 archives.csv を取得する。
  # 「初回でオブジェクトが存在しない」場合のみ空配列で開始し、
  # ネットワーク障害等の取得失敗では abort する。
  # (取得失敗を空扱いすると、既存台帳を空で上書きして全消失させてしまうため)
  def fetch_existing_archives(local_csv)
    return [] unless archives_exist?

    ok = system("gcloud", "storage", "cp", "gs://#{@bucket}/archives.csv", local_csv,
      out: File::NULL, err: File::NULL)
    abort("failed to fetch existing archives.csv (aborting to avoid overwriting the ledger)") unless ok && File.exist?(local_csv)

    CSV.read(local_csv)
  end

  def archives_exist?
    object_exists?("archives.csv")
  end

  # --- index.html --------------------------------------------------------

  def write_index(rows)
    local_html = File.join(Dir.tmpdir, "miyamai_index_#{Process.pid}.html")
    File.write(local_html, render_html(rows))
    gcloud_storage("cp", "--content-type=text/html; charset=utf-8", local_html, "gs://#{@bucket}/index.html")
  ensure
    File.delete(local_html) if local_html && File.exist?(local_html)
  end

  def render_html(rows)
    abort("no archives to render") if rows.empty?

    current = rows.first # 降順なので先頭が最新
    options = rows.map do |date, fname|
      label = date_with_slot(date, fname)
      selected = fname == current[1] ? " selected" : ""
      %(<option value="#{h(public_url(fname))}"#{selected}>#{h(label)}</option>)
    end.join("\n        ")

    TemplateRenderer.render("index.html", self,
      current:,
      current_url: public_url(current[1]),
      page_url: public_url("index.html"),
      feed_url: public_url("feed.xml"),
      manifest_url: public_url("manifest.json"),
      icon_url: public_url(ICON_IMAGE),
      cover_url: public_url(COVER_IMAGE),
      description: "#{date_with_slot(current[0], current[1])} — #{current[2]}",
      og_title: PROGRAM_NAME,
      options:)
  end

  # --- feed.xml (Atom) ---------------------------------------------------
  # archives.csv の全エピソードを新しい順のエントリにした Atom フィード。
  # 各エントリの content には、その回で紹介したニュース一覧(used_news)を
  # URL リンク化した HTML で入れる。used_news が無い過去分は content を空にする。

  def write_feed(rows)
    local_xml = File.join(Dir.tmpdir, "miyamai_feed_#{Process.pid}.xml")
    File.write(local_xml, render_feed(rows))
    gcloud_storage("cp", "--content-type=application/atom+xml; charset=utf-8", local_xml, "gs://#{@bucket}/feed.xml")
  ensure
    File.delete(local_xml) if local_xml && File.exist?(local_xml)
  end

  def render_feed(rows)
    abort("no archives to render") if rows.empty?

    entries = rows.map do |date, fname, title, used_news, updated_at|
      render_feed_entry(date, fname, title, used_news.to_s, updated_at)
    end.join("\n")

    TemplateRenderer.render("feed.xml", self,
      feed_url: public_url("feed.xml"),
      page_url: public_url("index.html"),
      updated: feed_datetime(rows.first[0], rows.first[4]), # 降順なので先頭が最新
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
      # id はエントリの一意識別子なので、回ごとに一意な mp3 URL のままにする
      # (全エントリで同じ index.html を id にすると RSS リーダーが区別できない)。
      entry_id: public_url(fname),
      updated: feed_datetime(date, updated_at),
      content: used_news.strip.empty? ? "" : h(used_news)).chomp
  end

  # --- manifest.json (PWA) -----------------------------------------------
  # ホーム画面追加(PWA)用の Web App Manifest。name は PROGRAM_NAME 固定で
  # エピソードごとには変わらないが、index/feed と同じく毎回書き出す。
  # アイコンは正方形が必要なので、横長の cover_image ではなく icon_image を使う。

  def write_manifest
    local_json = File.join(Dir.tmpdir, "miyamai_manifest_#{Process.pid}.json")
    File.write(local_json, render_manifest)
    gcloud_storage("cp", "--content-type=application/manifest+json; charset=utf-8", local_json, "gs://#{@bucket}/manifest.json")
  ensure
    File.delete(local_json) if local_json && File.exist?(local_json)
  end

  def render_manifest
    TemplateRenderer.render("manifest.json", self, icon_url: public_url(ICON_IMAGE))
  end

  # Atom の <updated> 用 RFC3339 日時を返す。
  # updated_at(生成時刻)があればそれを使う。持たない過去行は date の
  # 00:00:00 UTC にフォールバックする。
  # date の組み立てで Date#to_time を使わないのは、ローカルタイム扱いになり
  # UTC 変換で日付がずれるため。日付文字列をそのまま UTC 午前0時として組む。
  def feed_datetime(date_str, updated_at = nil)
    return updated_at if updated_at && !updated_at.to_s.strip.empty?

    "#{Date.parse(date_str).strftime('%Y-%m-%d')}T00:00:00Z"
  end

  # 現在時刻を UTC の RFC3339 秒精度で返す(例: 2026-07-10T05:11:23Z)。
  def now_rfc3339
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  # ファイル名末尾の slot(_morning/_afternoon/_evening/_midnight)を日本語ラベルにする。
  # 1日に複数回ある回を UI やフィードで見分けるための表示用。
  # slot を持たない旧ファイル名は空文字を返す(後方互換)。
  SLOT_LABELS = { "morning" => "朝", "afternoon" => "昼", "evening" => "夜", "midnight" => "深夜" }.freeze

  def slot_label(filename)
    m = filename.match(/_(morning|afternoon|evening|midnight)\.mp3\z/)
    m ? SLOT_LABELS.fetch(m[1]) : ""
  end

  # "YYYY-MM-DD" に slot ラベルを添えた表示用の日付。slot が無ければ日付のみ。
  def date_with_slot(date, filename)
    label = slot_label(filename)
    label.empty? ? date : "#{date}（#{label}）"
  end

  # ファイル名(miyamai_news_YYYYMMDD[_slot].mp3)の日付部分を archives.csv 用の
  # "YYYY-MM-DD" にする。GCS のオブジェクト名と同じくファイル名を正とすることで、
  # 過去分を日付指定なしで再アップロードしても date 列が今日にずれない。
  # ファイル名から日付が読めないときだけ @date にフォールバックする。
  def date_for(filename)
    m = filename.match(/(\d{4})(\d{2})(\d{2})/)
    m ? "#{m[1]}-#{m[2]}-#{m[3]}" : @date.to_s
  end

  def h(str)
    CGI.escapeHTML(str.to_s)
  end
end
