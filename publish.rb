# frozen_string_literal: true

require "csv"
require "date"
require "cgi"
require "erb"
require "shellwords"
require "tmpdir"
require_relative "config"

# 生成済み mp3 を GCS に置き、CSV 駆動でペライチ再生ページ(index.html)を更新する。
#
# 前提:
#   - gcloud が設定済み(認証・プロジェクト)
#   - バケットが公開読み取り可能(または署名URL運用なら別途調整)
#
# 使い方(音声生成スクリプトの末尾から):
#   MiyamaiNewsUploader.new(
#     date:  Date.today,
#     title: "技術ニュース #{Date.today.strftime('%Y-%m-%d')}",
#   ).run("/path/to/miyamai_news_20260710.mp3")
#   # bucket 未指定時は DEFAULT_BUCKET(nidodm-miyamai-news)を使用
#
# GCS 上のレイアウト:
#   gs://your-bucket/miyamai_news_YYYYMMDD.mp3   … 音声本体
#   gs://your-bucket/miyamai_news_YYYYMMDD.used.txt … その回で紹介したニュース一覧(任意)
#   gs://your-bucket/archives.csv                … アーカイブ台帳
#   gs://your-bucket/index.html                  … 再生ページ(毎回再生成)
#   gs://your-bucket/feed.xml                     … Atom フィード(毎回再生成)
#   gs://your-bucket/miyamai_news.png            … 横長バナー(Slackプレビュー+再生ページ共用, 事前に手動アップロード)
class MiyamaiNewsUploader
  PUBLIC_BASE    = Config.get("gcs.public_base")
  DEFAULT_BUCKET = Config.get("gcs.bucket")
  # 横長バナー画像。Slack のリンクプレビューと再生ページの両方で使う。
  # 事前に GCS へアップロードしておく:
  #   gcloud storage cp <cover_image> gs://<bucket>/<cover_image>
  COVER_IMAGE = Config.get("assets.cover_image")

  # ページ/フィードのマークアップは ERB テンプレート。実体はこのクラスの末尾に
  # 定数(INDEX_TEMPLATE / FEED_TEMPLATE / FEED_ENTRY_TEMPLATE)としてまとめてある。
  # 埋め込み変数は render_html / render_feed / render_feed_entry のローカル変数を参照する。
  # 値の HTML エスケープは呼び出し側の h() で行い、テンプレートでは素通しする。

  def initialize(bucket: DEFAULT_BUCKET, date: Date.today, title: nil)
    @bucket = bucket
    @date   = date
    @title  = title || "宮舞モカ 技術ニュース #{date.strftime('%Y-%m-%d')}"
  end

  # GCS 上のオブジェクト名は、渡された mp3 のファイル名をそのまま使う
  # （例: miyamai_news_20260710_afternoon.mp3）。日付から組み立て直すと
  # slot が落ちて朝昼夜が同名で上書きし合うため、呼び出し側のファイル名を正とする。
  def run(mp3_path, used_txt_path = nil)
    filename = File.basename(mp3_path)
    used_object = filename.sub(/\.mp3\z/, ".used.txt")

    upload_mp3(mp3_path, filename)
    upload_used_news(used_txt_path, used_object) if used_txt_path
    used_news = used_txt_path && File.exist?(used_txt_path) ? File.read(used_txt_path) : ""
    rows = update_archives(filename, used_news)
    write_index(rows)
    write_feed(rows)

    puts "done: #{public_url('index.html')}"
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
    system("gcloud", "storage", "ls", "gs://#{@bucket}/archives.csv",
           out: File::NULL, err: File::NULL)
  end

  # --- index.html --------------------------------------------------------

  def write_index(rows)
    local_html = File.join(Dir.tmpdir, "miyamai_index_#{Process.pid}.html")
    File.write(local_html, render_html(rows))
    gcloud_storage("cp", "--content-type=text/html; charset=utf-8", local_html, "gs://#{@bucket}/index.html")
  ensure
    File.delete(local_html) if local_html && File.exist?(local_html)
  end

  # ERB テンプレートを、呼び出し元の変数(binding)を使って描画する。
  def render(template, bind)
    ERB.new(template, trim_mode: "-").result(bind)
  end

  def render_html(rows)
    abort("no archives to render") if rows.empty?

    current = rows.first # 降順なので先頭が最新
    current_url = public_url(current[1])
    page_url = public_url("index.html")
    feed_url = public_url("feed.xml")
    cover_url = public_url(COVER_IMAGE)
    description = "#{date_with_slot(current[0], current[1])} — #{current[2]}"

    options = rows.map { |date, fname, title|
      label = "#{date_with_slot(date, fname)} — #{title}"
      selected = (fname == current[1]) ? " selected" : ""
      %(<option value="#{h(public_url(fname))}"#{selected}>#{h(label)}</option>)
    }.join("\n        ")

    render(INDEX_TEMPLATE, binding)
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

    feed_url = public_url("feed.xml")
    page_url = public_url("index.html")
    updated  = feed_datetime(rows.first[0], rows.first[4]) # 降順なので先頭が最新

    entries = rows.map { |date, fname, title, used_news, updated_at|
      render_feed_entry(date, fname, title, used_news.to_s, updated_at)
    }.join("\n")

    render(FEED_TEMPLATE, binding)
  end

  def render_feed_entry(date, fname, title, used_news, updated_at)
    # link は読者のクリック先なので再生ページ(index.html)にする。
    # id はエントリの一意識別子なので、回ごとに一意な mp3 URL のままにする
    # (全エントリで同じ index.html を id にすると RSS リーダーが区別できない)。
    entry_id  = public_url(fname)
    entry_url = public_url("index.html")
    updated   = feed_datetime(date, updated_at)
    content   = used_news.strip.empty? ? "" : h(used_news)
    # 同一日に複数回ある場合、entry の title が重複しないよう slot を添える。
    label = slot_label(fname)
    title = "#{title}（#{label}）" unless label.empty?

    render(FEED_ENTRY_TEMPLATE, binding).chomp
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

  # ファイル名末尾の slot(_morning/_afternoon/_evening)を日本語ラベルにする。
  # 1日に複数回ある回を UI やフィードで見分けるための表示用。
  # slot を持たない旧ファイル名は空文字を返す(後方互換)。
  SLOT_LABELS = { "morning" => "朝", "afternoon" => "昼", "evening" => "夜" }.freeze

  def slot_label(filename)
    m = filename.match(/_(morning|afternoon|evening)\.mp3\z/)
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

  # --- テンプレート(ERB) --------------------------------------------------
  # リテラル heredoc(<<~'...')で持つ。式展開もエスケープも行わないので、
  # JS の正規表現(\/ や \.)や ERB タグ(<%= %>)がそのまま保たれる。
  # 埋め込み変数は render_html / render_feed / render_feed_entry のローカル変数を
  # binding 経由で参照する。値の HTML エスケープはそれらの中の h() で行う。

  INDEX_TEMPLATE = <<~'HTML'
    <!DOCTYPE html>
    <html lang="ja">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title><%= h(@title) %></title>
      <link rel="alternate" type="application/atom+xml" title="宮舞モカ 技術ニュース" href="<%= h(feed_url) %>">

      <!-- Open Graph (Slack のリンクプレビュー用) -->
      <meta property="og:type" content="website">
      <meta property="og:title" content="<%= h(@title) %>">
      <meta property="og:description" content="<%= h(description) %>">
      <meta property="og:url" content="<%= h(page_url) %>">
      <meta property="og:image" content="<%= h(cover_url) %>">
      <meta property="og:audio" content="<%= h(current_url) %>">
      <meta property="og:audio:type" content="audio/mpeg">

      <!-- Twitter Summary Card (大きな画像付きプレビュー) -->
      <meta name="twitter:card" content="summary_large_image">
      <meta name="twitter:title" content="<%= h(@title) %>">
      <meta name="twitter:description" content="<%= h(description) %>">
      <meta name="twitter:image" content="<%= h(cover_url) %>">

      <style>
        /* 宮舞モカのイメージカラー #8DA7C2 を基調にした明るい配色 */
        :root {
          color-scheme: light;
          --moca: #8DA7C2;
          --moca-deep: #5f7d9e;
        }
        body {
          margin: 0;
          font-family: -apple-system, "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif;
          /* sticky footer 構成。主コンテンツ領域(.content)が残り高さを埋めるので
             footer は常にビューポート最下部に来る。 */
          display: flex;
          flex-direction: column;
          min-height: 100vh;
          background: var(--moca);
          color: #2b3440;
        }
        /* card を内包する主コンテンツ領域。flex:1 で残り高さを占め、footer を
           画面最下部へ押し下げる。card はこの中で中央寄せ。縦長になっても
           card の縦マージンが footer との間隔を保つ（密着しない）。 */
        .content {
          flex: 1;
          display: flex;
          align-items: center;
          justify-content: center;
          width: 100%;
          box-sizing: border-box;
          padding: 32px 0;
        }
        .card {
          width: min(520px, 92vw);
          padding: 28px;
          border-radius: 14px;
          background: #ffffff;
          box-shadow: 0 8px 32px rgba(95, 125, 158, .25);
        }
        .art {
          display: block;
          width: 100%;
          height: auto;
          margin: 0 auto 16px;
          border-radius: 12px;
          border: 3px solid var(--moca);
        }
        h1 { font-size: 15px; font-weight: 600; margin: 0 0 4px; letter-spacing: .02em; text-align: center; color: var(--moca-deep); }
        .sub { font-size: 12px; color: #7a8896; margin: 0 0 20px; text-align: center; }
        select {
          width: 100%;
          padding: 10px 12px;
          margin-bottom: 16px;
          border-radius: 8px;
          border: 1px solid var(--moca);
          background: #f5f8fb;
          color: #2b3440;
          font-size: 13px;
        }
        audio { width: 100%; }
        .news {
          margin-top: 20px;
          border-top: 1px solid #e2e8f0;
          padding-top: 16px;
        }
        .news h2 { font-size: 12px; font-weight: 600; margin: 0 0 10px; color: var(--moca-deep); }
        .news pre {
          margin: 0;
          white-space: pre-wrap;
          word-break: break-word;
          font-family: inherit;
          font-size: 12px;
          line-height: 1.6;
          color: #3a4652;
        }
        .news a { color: var(--moca-deep); }
        /* ビューポート最下部に敷く半透明の帯。モカ背景の上に置くため
           白の半透明地に濃色文字で、どの背景でも読めるようにする。 */
        .site-footer {
          width: 100%;
          box-sizing: border-box;
          padding: 14px 20px;
          background: rgba(255, 255, 255, .82);
          backdrop-filter: blur(6px);
          text-align: center;
        }
        .site-footer .subscribe {
          margin: 0 0 8px;
          font-size: 12px;
        }
        /* クレジット各項目は横並び。横幅が足りなければ折り返して縦積みになる。
           column-gap が項目間、row-gap が折り返し時の行間。 */
        .site-footer .credits {
          margin: 0;
          display: flex;
          flex-wrap: wrap;
          justify-content: center;
          gap: 4px 20px;
          font-size: 11px;
          line-height: 1.7;
          color: #5f6b78;
        }
        .site-footer .credits p { margin: 0; }
        .site-footer a { color: var(--moca-deep); }
      </style>
    </head>
    <body>
      <main class="content">
        <div class="card">
          <img class="art" src="<%= h(cover_url) %>" alt="宮舞モカ">
          <h1>宮舞モカ 技術ニュース</h1>
          <p class="sub" id="nowplaying"><%= h(date_with_slot(current[0], current[1])) %> — <%= h(current[2]) %></p>
          <select id="archive" aria-label="アーカイブ選択">
            <%= options %>
          </select>
          <audio id="player" controls src="<%= h(current_url) %>"></audio>
          <div class="news">
            <h2>この回で紹介したニュース</h2>
            <pre id="newslist">読み込み中…</pre>
          </div>
        </div>
      </main>

      <footer class="site-footer">
        <p class="subscribe"><a href="<%= h(feed_url) %>">フィード（Atom）で購読</a></p>
        <div class="credits">
          <p>音声：VOICEPEAK 宮舞モカ（© 株式会社AHS）<a href="https://www.ah-soft.com/voice/moca/eula.html" target="_blank" rel="noopener">使用許諾</a></p>
          <p>立ち絵：からい 様（<a href="https://seiga.nicovideo.jp/seiga/im11390154" target="_blank" rel="noopener">宮舞モカ立ち絵素材</a>）</p>
          <p>BGM：猫きまぐれBGM工房 様「古びた魔法書」（<a href="https://kim4gure.com/" target="_blank" rel="noopener">猫きまぐれBGM工房</a>）</p>
        </div>
      </footer>

      <script>
        const sel = document.getElementById('archive');
        const player = document.getElementById('player');
        const now = document.getElementById('nowplaying');
        const newslist = document.getElementById('newslist');

        const escapeHtml = (s) => s
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;');

        // 先にエスケープしてから URL だけをリンク化する(挿入する href/文字列はエスケープ済み)
        const linkify = (text) =>
          escapeHtml(text).replace(/https?:\/\/[^\s<]+/g,
            (url) => `<a href="${url}" target="_blank" rel="noopener">${url}</a>`);

        // mp3 の URL から used.txt の URL を導出(miyamai_news_YYYYMMDD.mp3 → .used.txt)
        const usedUrlFor = (mp3Url) => mp3Url.replace(/\.mp3$/, '.used.txt');

        const loadNews = async (mp3Url) => {
          newslist.textContent = '読み込み中…';
          try {
            const res = await fetch(usedUrlFor(mp3Url), { cache: 'no-cache' });
            if (!res.ok) throw new Error(res.status);
            newslist.innerHTML = linkify(await res.text());
          } catch (e) {
            newslist.textContent = 'ニュース一覧はありません';
          }
        };

        // アーカイブ選択では src とニュース一覧だけ差し替え、再生はしない。
        // 再生はユーザーが再生ボタンを押したときだけ始まるようにする。
        sel.addEventListener('change', () => {
          player.src = sel.value;
          now.textContent = sel.options[sel.selectedIndex].text;
          loadNews(sel.value);
        });

        loadNews(player.src);
      </script>
    </body>
    </html>
  HTML

  FEED_TEMPLATE = <<~'XML'
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>宮舞モカ 技術ニュース</title>
      <subtitle>エンジニア向けの技術ニュースを宮舞モカがお届けします</subtitle>
      <link rel="self" type="application/atom+xml" href="<%= h(feed_url) %>"/>
      <link rel="alternate" type="text/html" href="<%= h(page_url) %>"/>
      <id><%= h(feed_url) %></id>
      <updated><%= updated %></updated>
    <%= entries %>
    </feed>
  XML

  # feed 内での entry のインデント(2スペース)を出力にそのまま反映したいので、
  # インデント除去する <<~ ではなく生の <<'...' を使う。行頭からの空白が
  # そのままテンプレートの一部になる(終端の XML だけは行頭に置く)。
  FEED_ENTRY_TEMPLATE = <<'XML'
  <entry>
    <title><%= h(title) %></title>
    <link rel="alternate" type="text/html" href="<%= h(entry_url) %>"/>
    <id><%= h(entry_id) %></id>
    <updated><%= updated %></updated>
    <content type="html"><%= content %></content>
  </entry>
XML
end

# 直接実行された場合の簡易 CLI:
#   ruby publish.rb <mp3_path> [bucket] [YYYY-MM-DD] [title]
#   bucket 省略時は DEFAULT_BUCKET(nidodm-miyamai-news)を使用
#   ニュース一覧は mp3 と同名の .used.txt(例:
#   miyamai_news_YYYYMMDD_afternoon.used.txt)があれば自動でアップロードする。
#   GCS 上のオブジェクト名は mp3 のファイル名をそのまま使う(slot を保持)。
if __FILE__ == $PROGRAM_NAME
  usage = "usage: ruby #{$0} <mp3_path> [bucket] [YYYY-MM-DD] [title]"
  mp3    = ARGV[0] or abort(usage)
  bucket = ARGV[1]
  date   = ARGV[2] ? Date.parse(ARGV[2]) : Date.today
  title  = ARGV[3]

  used = mp3.sub(/\.mp3\z/, ".used.txt")
  used = nil unless File.exist?(used)

  opts = { date: date, title: title }
  opts[:bucket] = bucket if bucket
  MiyamaiNewsUploader.new(**opts).run(mp3, used)
end
