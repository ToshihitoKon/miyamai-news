# frozen_string_literal: true

require "date"
require "csv"
require "json"
require "cgi"
require "shellwords"
require "tmpdir"
require "open3"
require_relative "internal/config"
require_relative "internal/template_renderer"
require_relative "internal/command_error"

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

  # 1回のエピソードを構成するファイルの拡張子。mp3 のファイル名からの
  # 置換規則(拡張子違いの同名ファイル)を1箇所にまとめ、run/archive_episode_files
  # など複数箇所での置換ロジックの重複・食い違いを防ぐ。新しい付随ファイルが
  # 増えたときはここに追加すればよい。
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

  # 既存 archives.csv を読み込んで index.html / manifest.json だけを再生成する。
  # mp3・used.txt・archives.csv・feed.xml には一切触れない。UI 文言だけを直したときに、
  # 新しい回を公開したとの誤解（Atom の <updated> 更新による通知）を避けつつ、
  # 表示だけ即時反映したい場合に使う。
  def republish_ui
    local_csv = File.join(Dir.tmpdir, "miyamai_archives_#{Process.pid}.csv")
    rows = fetch_existing_archives(local_csv)
    abort("archives.csv does not exist yet (nothing published)") if rows.empty?

    write_index(rows)
    write_manifest

    puts "done (UI only): #{public_url('index.html')}"
  ensure
    File.delete(local_csv) if local_csv && File.exist?(local_csv)
  end

  # 指定オブジェクトが GCS のバケットに存在するか。
  # 「オブジェクトが存在しない」（gcloud 自体は正常応答）と「確認に失敗した」
  # （ネットワーク障害・認証失効・gcloud 不在等）を区別する。後者を false 扱いすると、
  # archives_exist? 経由で「初回で台帳が無い」と誤認し、既存 archives.csv を新規1行で
  # 上書きして過去エピソードの一覧を全消失させかねないため、後者は例外にして呼び出し元で
  # 中断させる。
  def object_exists?(object)
    _out, err, status = Open3.capture3("gcloud", "storage", "ls", "gs://#{@bucket}/#{object}")
    return true if status.success?
    # gcloud storage ls は「オブジェクトが無い」場合もこのメッセージで exit code 1 を
    # 返す。exit code だけでは他の失敗（認証切れ・ネットワーク障害等）と区別できないため、
    # メッセージの内容で判定する。
    return false if err.include?("matched no objects")

    raise "gcloud storage ls failed (not a \"no objects\" result, treating as a transient " \
      "failure to avoid mistaking it for absence): #{Internal::CommandError.tail(err)}"
  rescue Errno::ENOENT => e
    raise "gcloud not found: #{e.message}"
  end

  # archived/ プレフィックス配下(update_archives が退避させた保持件数超過分)を
  # まとめて実削除する。publish 時の隔離処理とは独立して、明示的に呼ばれたときだけ動く。
  # archived/ が空の場合はワイルドカードがマッチせず gcloud storage rm がエラーになるが、
  # 「削除するものが無かった」だけなので abort しない。それ以外の失敗
  # （認証切れ・ネットワーク障害等）は区別して abort する。
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

  # 横長バナー画像。Slack のリンクプレビューと再生ページの両方で使う。
  # GCS への事前アップロードが前提（README 参照）。
  def cover_image = Config.assets.cover_image

  # PWA(ホーム画面追加)用の正方形アイコン。manifest.json から参照する。
  # cover_image と同じく GCS への事前アップロードが前提（README 参照）。
  def icon_image = Config.assets.icon_image

  def public_url(object)
    "#{public_base}/#{@bucket}/#{object}"
  end

  def gcloud_storage(*args)
    cmd = ["gcloud", "storage", *args].shelljoin
    system(cmd) || abort("gcloud storage failed: #{cmd}")
  end

  def gcloud_storage_mv(object)
    cmd = ["gcloud", "storage", "mv", "gs://#{@bucket}/#{object}", "gs://#{@bucket}/archived/#{object}"].shelljoin
    raise "gcloud storage mv failed: #{cmd}" unless system(cmd)
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
  # 列: date(YYYY-MM-DD), filename, title, used_news, updated_at(RFC3339 UTC)
  # used_news はその回で紹介したニュース一覧の全文(Atom フィードの content 用)。
  # updated_at は生成時刻。当日分を作り直すたびに更新され、Atom の <updated> に
  # 使う。これにより同じ日に再生成しても更新が進み、RSS リーダーが検知できる。
  # 4列目を持たない過去の行は used_news 空、5列目を持たない過去の行は
  # updated_at 空(date の 00:00:00Z にフォールバック)として扱う。
  # 同一 filename は上書き。1日に複数回(朝昼夜)ある場合は date が同じでも
  # filename が異なる行として共存する。降順(新しい順)で保持。
  # retention_episodes を超えた古い回は台帳から外し、実ファイルは archived/ へ退避する
  # (削除はしない。実削除は Publisher#clean_archive で行う)。

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

    expired_rows = rows.drop(retention_episodes)
    rows = rows.first(retention_episodes)
    expired_rows.each { |r| archive_episode_files(r[1]) }

    CSV.open(local_csv, "w") { |csv| rows.each { |r| csv << r } }
    gcloud_storage("cp", "--content-type=text/csv", local_csv, "gs://#{@bucket}/archives.csv")

    rows
  ensure
    File.delete(local_csv) if local_csv && File.exist?(local_csv)
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

  # 既存 archives.csv を取得する。
  # 「初回でオブジェクトが存在しない」場合のみ空配列で開始し、
  # ネットワーク障害等の取得失敗では abort する。
  # (取得失敗を空扱いすると、既存台帳を空で上書きして全消失させてしまうため)
  # archives_exist? 自体がネットワーク障害等では例外を送出する（object_exists? 参照）ので、
  # ここで rescue せず呼び出し元まで伝播させて publish 全体を中断させる。
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
    gcloud_storage("cp",
      "--content-type=text/html; charset=utf-8",
      "--cache-control=public, max-age=300",
      local_html, "gs://#{@bucket}/index.html")
  ensure
    File.delete(local_html) if local_html && File.exist?(local_html)
  end

  def render_html(rows)
    abort("no archives to render") if rows.empty?

    current = rows.first # 降順なので先頭が最新
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
      # content type="html" の中身は「XMLデコード後にHTMLとして解釈される」仕様なので、
      # 組み立てた HTML 片(<br>/<a>を含む)をそのまま埋めるとタグとして解釈されてしまう。
      # h() でもう一段 XML エスケープしてから埋め込む。
      content: used_news.strip.empty? ? "" : h(used_news_html(used_news))).chomp
  end

  # used_news(改行区切りのプレーンテキスト)を、content type="html" 向けの HTML に組み立てる。
  # index.html.erb 側の JS 表示（改行を無視せず、URL をリンク化する）と揃える。
  # 手順: 本文を先に h() で丸ごとエスケープしてから URL をリンク化し、最後に改行を <br> に
  # 変える（h() を先にかけないと、生成した <a> タグ自体がエスケープされてしまう）。
  def used_news_html(used_news)
    h(used_news)
      .gsub(%r{https?://[^\s&]+}) { |url| %(<a href="#{url}">#{url}</a>) }
      .gsub("\n", "<br>\n")
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
    TemplateRenderer.render("manifest.json", self, icon_url: public_url(icon_image))
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
