# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "date"
require "csv"
require "publisher"

RSpec.describe Publisher do
  let(:work_dir) { Dir.mktmpdir }
  let(:mp3_path) { File.join(work_dir, "miyamai_news_20260714_afternoon.mp3") }
  let(:used_path) { File.join(work_dir, "miyamai_news_20260714_afternoon.used.txt") }
  let(:transcript_path) { File.join(work_dir, "miyamai_news_20260714_afternoon.transcript.txt") }

  # R2 は S3 互換 API なので stub_responses でクライアントごと差し替える。
  let(:s3) { Aws::S3::Client.new(stub_responses: true, region: "auto") }
  let(:storage) { Internal::R2Storage.new(bucket: "test-bucket", client: s3) }
  # サイトの反映は subprocess を起動せず、渡されたディレクトリだけ記録する。
  let(:deployed) { [] }
  let(:deploy_result) { [true] }
  let(:site) do
    Internal::Site.new(
      public_base: "https://news.example.com",
      retention_episodes: 5,
      storage: storage,
      deployer: ->(dir) {
        deployed << { dir: dir, files: Dir.exist?(dir) ? Dir.children(dir) : [] }
        deploy_result.first
      }
    )
  end

  before do
    File.write(mp3_path, "fake mp3")
    File.write(used_path, "## 生成AI\n### [Title A](https://example.com/a)\n   要約です。\n   (2026-07-14 / SourceA)\n")
    File.write(transcript_path, "宮舞モカです。\n")
  end

  after { FileUtils.remove_entry(work_dir) }

  # notify の呼び出しを記録するだけのスパイ。web_push が未設定でも Publisher の
  # デフォルト（NullNotifier）に隠れて検証漏れにならないよう、明示的に注入する。
  let(:notified) { [] }
  let(:notifier) do
    n = double("notifier")
    allow(n).to receive(:notify) { |**kwargs| notified << kwargs }
    n
  end

  def build_publisher(ledger: nil, **kwargs)
    s3.stub_responses(:head_object, ledger.nil? ? "NotFound" : {})
    s3.stub_responses(:get_object, { body: ledger.to_s }) unless ledger.nil?
    s3.stub_responses(:put_object, {})
    s3.stub_responses(:copy_object, { copy_object_result: {} })
    s3.stub_responses(:delete_object, {})
    described_class.new(date: Date.new(2026, 7, 14), site: site, notifier: notifier, **kwargs)
  end

  def ledger_csv(rows) = CSV.generate { |csv| rows.each { |r| csv << r } }

  # 反映されたステージングの中身（バージョン単位反映なので、ここに無い
  # ファイルは公開サイトから消える）。
  def staged_files = deployed.flat_map { |d| d[:files] }

  describe "#run" do
    it "uploads the episode files to R2 and deploys the site once" do
      publisher = build_publisher
      put_keys = []
      s3.stub_responses(:put_object, ->(ctx) { put_keys << ctx.params[:key]; {} })

      publisher.run(mp3_path, used_path, transcript_path)

      expect(put_keys).to include("episodes/#{File.basename(mp3_path)}")
      expect(put_keys).to include("episodes/#{File.basename(used_path)}")
      expect(put_keys).to include("episodes/miyamai_news_20260714_afternoon.used.html")
      expect(put_keys).to include("episodes/#{File.basename(transcript_path)}")
      expect(put_keys).to include("archives.csv")
      expect(deployed.size).to eq(1)
    end

    # デプロイはバージョン単位なので、生成ページが毎回すべてステージングに
    # 揃っていないと公開サイトから消える。
    it "stages every generated page" do
      publisher = build_publisher

      publisher.run(mp3_path, used_path, transcript_path)

      expect(staged_files).to include("index.html", "feed.xml", "manifest.json", "_headers")
    end

    it "does not stage sw.js when web_push is not configured" do
      publisher = build_publisher

      publisher.run(mp3_path, used_path, transcript_path)

      expect(staged_files).not_to include("sw.js")
    end

    # --ui-only 実行のたびに反映されるバージョン単位デプロイなので、ここに
    # 含めないと sw.js が公開サイトから消え、既存の購読が壊れる。
    it "stages sw.js when web_push is configured" do
      allow(Config).to receive(:web_push).and_return(double("web_push", vapid_public_key: "test-key"))
      publisher = build_publisher

      publisher.run(mp3_path, used_path, transcript_path)

      expect(staged_files).to include("sw.js")
    end

    # 画像は R2 に置くので、手元に実体が無くても publish できる必要がある
    # （版権素材をリポジトリに置かないため）。
    it "does not require the artwork to exist locally" do
      FileUtils.rm_f(Config.assets.icon_image)
      FileUtils.rm_f(Config.assets.cover_image)
      publisher = build_publisher

      expect { publisher.run(mp3_path, used_path, transcript_path) }.not_to raise_error
      expect(staged_files).not_to include(File.basename(Config.assets.icon_image))
    end

    it "aborts before touching R2 when used_news fails validation and repair" do
      publisher = build_publisher
      File.write(used_path, "・タイトルだけの旧フォーマット\nhttps://example.com/a\n")
      allow(UsedNewsFormatter).to receive(:run_fix_cli).and_return(nil)
      put_called = false
      s3.stub_responses(:put_object, ->(_ctx) { put_called = true; {} })

      expect { publisher.run(mp3_path, used_path, transcript_path) }.to raise_error(SystemExit)
      expect(put_called).to be false
      expect(deployed).to be_empty
    end

    it "does not validate used_news when used_txt_path is nil" do
      publisher = build_publisher
      allow(UsedNewsFormatter).to receive(:ensure_valid!)

      publisher.run(mp3_path, nil, transcript_path)

      expect(UsedNewsFormatter).not_to have_received(:ensure_valid!)
    end

    # used.txt が work/ の掃除等でローカルから既に消えている状態で同じ episode を
    # 再 publish しても、記録済みの used_news との差分を誤検知して再通知しない。
    it "does not notify when re-publishing without used_txt_path even though the archive already has used_news" do
      title = "回タイトル"
      existing = [["2026-07-14", File.basename(mp3_path), title, File.read(used_path), "2026-07-14T00:00:00Z"]]
      publisher = build_publisher(ledger: ledger_csv(existing), title: title)

      publisher.run(mp3_path, nil, transcript_path)

      expect(notified).to be_empty
    end

    it "aborts the whole run when the site deploy fails" do
      publisher = build_publisher
      deploy_result[0] = false

      expect { publisher.run(mp3_path, used_path, transcript_path) }.to raise_error(SystemExit)
    end

    it "notifies for a brand-new episode" do
      publisher = build_publisher(title: "回タイトル")

      publisher.run(mp3_path, used_path, transcript_path)

      expect(notified).to contain_exactly(
        { title: "新着ニュースが公開されました", body: "2026-07-14 昼", url: "https://news.example.com/" }
      )
    end

    it "does not notify when re-publishing identical title and used_news" do
      title = "回タイトル"
      existing = [["2026-07-14", File.basename(mp3_path), title, File.read(used_path),
        "2026-07-14T00:00:00Z"]]
      publisher = build_publisher(ledger: ledger_csv(existing), title: title)

      publisher.run(mp3_path, used_path, transcript_path)

      expect(notified).to be_empty
    end
  end

  describe "#republish_ui" do
    let(:existing) { [["2026-07-14", "miyamai_news_20260714_morning.mp3", "T", "", "2026-07-14T00:00:00Z"]] }

    it "deploys the site without writing the ledger or episode files" do
      publisher = build_publisher(ledger: ledger_csv(existing))
      put_keys = []
      s3.stub_responses(:put_object, ->(ctx) { put_keys << ctx.params[:key]; {} })

      publisher.republish_ui

      expect(deployed.size).to eq(1)
      expect(put_keys).to be_empty
      expect(staged_files).to include("index.html", "feed.xml", "manifest.json")
    end

    it "does not notify (UI-only republish never fires a push notification)" do
      publisher = build_publisher(ledger: ledger_csv(existing))

      publisher.republish_ui

      expect(notified).to be_empty
    end

    it "aborts when the ledger does not exist yet" do
      publisher = build_publisher

      expect { publisher.republish_ui }.to raise_error(SystemExit)
      expect(deployed).to be_empty
    end
  end

  # Content-Type は R2 のメタデータとして保存され Worker がそのまま返すため、
  # 誤った値でも配信は 200 で通り、再生や表示だけが静かに壊れる。
  describe "content types" do
    it "stores each episode file with a valid, correct media type" do
      publisher = build_publisher
      seen = {}
      s3.stub_responses(:put_object, ->(ctx) { seen[ctx.params[:key]] = ctx.params[:content_type]; {} })

      publisher.run(mp3_path, used_path, transcript_path)

      base = "episodes/miyamai_news_20260714_afternoon"
      expect(seen["#{base}.mp3"]).to eq("audio/mpeg")
      expect(seen["#{base}.used.html"]).to start_with("text/html")
      expect(seen["#{base}.used.txt"]).to start_with("text/plain")
      expect(seen["#{base}.transcript.txt"]).to start_with("text/plain")
      expect(seen["archives.csv"]).to eq("text/csv")
    end

    # プレフィックス名が MIME タイプへ紛れ込む一括置換の事故を防ぐ
    # （episodes/mpeg のような値は IANA のトップレベル型に無い）。
    it "never uses a storage prefix as a media type" do
      publisher = build_publisher
      types = []
      s3.stub_responses(:put_object, ->(ctx) { types << ctx.params[:content_type]; {} })

      publisher.run(mp3_path, used_path, transcript_path)

      valid_toplevel = %w[application audio font image model multipart text video]
      types.compact.each do |type|
        expect(valid_toplevel).to include(type.split("/").first)
      end
    end
  end

  describe "#upload_content" do
    it "writes under the episode prefix with the given content type" do
      publisher = build_publisher
      captured = nil
      s3.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      publisher.send(:upload_content, "a.used.txt", "body", content_type: "text/plain; charset=utf-8")

      expect(captured[:key]).to eq("episodes/a.used.txt")
      expect(captured[:content_type]).to eq("text/plain; charset=utf-8")
      expect(captured[:body]).to eq("body")
    end
  end

  describe "#run with retention_episodes" do
    # spec/fixtures/config.yaml の cloudflare.retention_episodes: 5 が前提。
    let(:existing_rows) do
      (1..5).map do |n|
        date = Date.new(2026, 6, 1) + n
        fname = "miyamai_news_#{date.strftime('%Y%m%d')}_morning.mp3"
        [date.to_s, fname, "宮舞モカの技術ニュース #{date}", "", "#{date}T00:00:00Z"]
      end
    end
    let(:oldest_fname) { existing_rows.first[1] }

    # 退避先が episodes プレフィックス配下だと Worker が R2 から配信し続け、
    # retention を超えた回が公開されたままになる。
    it "moves expired episodes out of the episode prefix" do
      publisher = build_publisher(ledger: ledger_csv(existing_rows))
      copies = []
      s3.stub_responses(:copy_object, ->(ctx) { copies << ctx.params; { copy_object_result: {} } })

      publisher.run(mp3_path, used_path, transcript_path)

      moved = copies.map { |c| [c[:copy_source], c[:key]] }
      expect(moved).to include(["test-bucket/episodes/#{oldest_fname}", "archived/#{oldest_fname}"])
      expect(copies.map { |c| c[:key] }).to all(start_with("archived/"))
    end

    it "does not move anything when within the retention limit" do
      publisher = build_publisher
      copied = false
      s3.stub_responses(:copy_object, ->(_ctx) { copied = true; { copy_object_result: {} } })

      publisher.run(mp3_path, used_path, transcript_path)

      expect(copied).to be false
    end

    it "aborts instead of overwriting the ledger when the existence check fails transiently" do
      publisher = build_publisher
      s3.stub_responses(:head_object, "InternalError")

      expect { publisher.run(mp3_path, used_path, transcript_path) }
        .to raise_error(Aws::S3::Errors::ServiceError)
      expect(deployed).to be_empty
    end
  end

  describe "#clean_archive" do
    it "deletes everything under the archived prefix" do
      publisher = build_publisher
      s3.stub_responses(:list_objects_v2, {
        contents: [{ key: "archived/a.mp3" }, { key: "archived/b.mp3" }], is_truncated: false,
      })
      captured = nil
      s3.stub_responses(:delete_objects, ->(ctx) { captured = ctx.params; {} })

      publisher.clean_archive

      expect(captured[:delete][:objects].map { |o| o[:key] }).to eq(["archived/a.mp3", "archived/b.mp3"])
    end

    it "does not fail when the archived prefix is empty" do
      publisher = build_publisher
      s3.stub_responses(:list_objects_v2, { contents: [], is_truncated: false })

      expect { publisher.clean_archive }.not_to raise_error
    end
  end

  describe "#object_exists?" do
    it "returns true when the object is present" do
      publisher = build_publisher
      s3.stub_responses(:head_object, {})

      expect(publisher.object_exists?("foo.mp3")).to be true
    end

    it "returns false on genuine absence" do
      publisher = build_publisher
      s3.stub_responses(:head_object, "NotFound")

      expect(publisher.object_exists?("foo.mp3")).to be false
    end

    # 確認失敗を「存在しない」と誤ると既存台帳を上書き消失させる。
    it "raises instead of returning false on a transient failure" do
      publisher = build_publisher
      s3.stub_responses(:head_object, "InternalError")

      expect { publisher.object_exists?("foo.mp3") }.to raise_error(Aws::S3::Errors::ServiceError)
    end
  end

  describe "#public_url" do
    let(:publisher) { build_publisher }

    it "serves the generated pages from the site root" do
      expect(publisher.send(:public_url, "index.html")).to eq("https://news.example.com/")
      expect(publisher.send(:public_url, "feed.xml")).to eq("https://news.example.com/feed.xml")
    end

    # feed の <link> や og:url にリダイレクトされる URL を載せない。
    it "never emits the redirecting /index.html form in the rendered feed" do
      rows = [["2026-07-14", "miyamai_news_20260714_afternoon.mp3", "T", "", "2026-07-14T00:00:00Z"]]

      expect(publisher.send(:render_feed, rows)).not_to include("/index.html")
    end

    # 再生ページの JS は mp3 URL の拡張子だけを差し替えて兄弟ファイルを引くため、
    # mp3 とその派生物は同じ階層に並んでいる必要がある。
    it "serves episode files from the episode prefix so sibling derivation works" do
      mp3 = publisher.send(:public_url, "ep.mp3")

      expect(mp3).to eq("https://news.example.com/episodes/ep.mp3")
      expect(mp3.sub(/\.mp3\z/, ".used.html")).to eq("https://news.example.com/episodes/ep.used.html")
    end
  end

  describe "#update_archives updated_at semantics" do
    let(:title) { "宮舞モカの技術ニュース 2026-07-14" }
    let(:used_news) { File.read(used_path) }
    let(:published_at) { "2026-07-14T01:23:45Z" }

    def existing_row(title:, used_news:, updated_at: "2026-07-14T01:23:45Z")
      ["2026-07-14", File.basename(mp3_path), title, used_news, updated_at]
    end

    def updated_at_after_run(row)
      publisher = build_publisher(ledger: ledger_csv([row]), title: title)
      rows, = publisher.send(:update_archives, File.basename(mp3_path), used_news)
      rows.find { |r| r[1] == File.basename(mp3_path) }[4]
    end

    it "keeps the existing updated_at when re-publishing identical title and used_news" do
      expect(updated_at_after_run(existing_row(title: title, used_news: used_news, updated_at: published_at)))
        .to eq(published_at)
    end

    it "advances updated_at when used_news changed" do
      expect(updated_at_after_run(existing_row(title: title, used_news: "## 別の内容\n", updated_at: published_at)))
        .not_to eq(published_at)
    end

    it "advances updated_at when the title changed" do
      expect(updated_at_after_run(existing_row(title: "古いタイトル", used_news: used_news, updated_at: published_at)))
        .not_to eq(published_at)
    end

    it "assigns the current time for a brand-new episode" do
      publisher = build_publisher(title: title)

      rows, = publisher.send(:update_archives, File.basename(mp3_path), used_news)

      expect(rows.first[4]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    # 空のまま引き継ぐと <updated> が空になり Atom として壊れる。
    it "falls back to the current time when the existing updated_at is blank" do
      expect(updated_at_after_run(existing_row(title: title, used_news: used_news, updated_at: "")))
        .to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it "does not move feed <updated> when re-publishing identical content" do
      row = existing_row(title: title, used_news: used_news, updated_at: published_at)
      publisher = build_publisher(ledger: ledger_csv([row]), title: title)

      rows, = publisher.send(:update_archives, File.basename(mp3_path), used_news)

      expect(publisher.send(:render_feed, rows)).to include("<updated>#{published_at}</updated>")
    end
  end

  describe "#update_archives newly_published semantics" do
    let(:title) { "宮舞モカの技術ニュース 2026-07-14" }
    let(:used_news) { File.read(used_path) }

    def existing_row(title:, used_news:, updated_at: "2026-07-14T01:23:45Z")
      ["2026-07-14", File.basename(mp3_path), title, used_news, updated_at]
    end

    def newly_published_after_run(row)
      publisher = build_publisher(ledger: ledger_csv([row]), title: title)
      _rows, newly_published = publisher.send(:update_archives, File.basename(mp3_path), used_news)
      newly_published
    end

    it "is true for a brand-new episode" do
      publisher = build_publisher(title: title)
      _rows, newly_published = publisher.send(:update_archives, File.basename(mp3_path), used_news)

      expect(newly_published).to be true
    end

    it "is false when re-publishing identical title and used_news" do
      expect(newly_published_after_run(existing_row(title: title, used_news: used_news))).to be false
    end

    it "is true when used_news changed" do
      expect(newly_published_after_run(existing_row(title: title, used_news: "## 別の内容\n"))).to be true
    end

    it "is true when the title changed" do
      expect(newly_published_after_run(existing_row(title: "古いタイトル", used_news: used_news))).to be true
    end

    # used_txt_path が渡らない再 publish（used.txt がローカルから既に消えている等）は
    # load_and_validate_used_news が空文字列を返すが、これは「used_news を空へ変更した」
    # わけではないので、used_news_given: false のときは used_news の差分を無視する。
    it "is false when re-publishing without used_txt_path even if the archived used_news is non-empty" do
      row = existing_row(title: title, used_news: used_news)
      publisher = build_publisher(ledger: ledger_csv([row]), title: title)

      _rows, newly_published = publisher.send(:update_archives, File.basename(mp3_path), "", used_news_given: false)

      expect(newly_published).to be false
    end

    it "is still true when the title changed even if used_news_given is false" do
      row = existing_row(title: "古いタイトル", used_news: used_news)
      publisher = build_publisher(ledger: ledger_csv([row]), title: title)

      _rows, newly_published = publisher.send(:update_archives, File.basename(mp3_path), "", used_news_given: false)

      expect(newly_published).to be true
    end
  end

  # <id> は RSS リーダー側の重複判定キー。ここが動くと購読者に全エピソードが
  # 新着として再通知されるので、配信 URL から独立した tag URI に固定する。
  describe "feed identifiers" do
    let(:publisher) { build_publisher }
    let(:rows) do
      [["2026-07-14", "miyamai_news_20260714_afternoon.mp3", "回タイトル", "", "2026-07-14T00:00:00Z"]]
    end

    it "identifies each entry by a tag URI derived from date and episode name" do
      xml = publisher.send(:render_feed, rows)

      expect(xml).to include("<id>tag:news.example.com,2026-07-14:miyamai_news_20260714_afternoon</id>")
    end

    it "identifies the feed itself by a fixed tag URI" do
      xml = publisher.send(:render_feed, rows)

      expect(xml).to include("<id>tag:news.example.com,#{Publisher::FEED_ID_DATE}:feed</id>")
    end

    # 配信 URL を <id> に埋めると、ドメインやパスを変えた時点で全件が
    # 新着扱いになる。
    it "keeps delivery URLs out of every id" do
      ids = publisher.send(:render_feed, rows).scan(%r{<id>(.*?)</id>}).flatten

      expect(ids).not_to be_empty
      expect(ids).to all(start_with("tag:"))
      expect(ids).to all(satisfy { |id| !id.include?("https://") })
    end

    it "gives entries and the feed distinct ids" do
      ids = publisher.send(:render_feed, rows).scan(%r{<id>(.*?)</id>}).flatten

      expect(ids.uniq.size).to eq(ids.size)
    end
  end

  describe "#render_feed_entry" do
    let(:publisher) { build_publisher }

    def content_of(xml)
      xml[%r{<content type="html">(.*)</content>}m, 1]
    end

    def render(used_news)
      xml = publisher.send(:render_feed_entry, "2026-07-14", "miyamai_news_20260714_morning.mp3",
        "宮舞モカの技術ニュース", used_news, "2026-07-14T00:00:00Z")
      content_of(xml)
    end

    # 新フォーマット（## カテゴリ / ### [タイトル](URL)）は構造化 HTML になる。
    context "with the new Markdown format" do
      let(:used_news) do
        <<~USED
          ## 生成AI
          ### [Gemini 3.5 Pro が延期か](https://example.com/gemini)
             次世代 LLM の開発が難航しているという観測。
             (2026-07-17 / 財経新聞)
        USED
      end

      it "renders structured HTML with the title linked, surviving both decode steps" do
        xml_decoded = CGI.unescapeHTML(render(used_news))

        expect(xml_decoded).to include('<div class="news-cat">生成AI</div>')
        expect(xml_decoded).to include(
          '<div class="news-title"><a href="https://example.com/gemini" target="_blank" rel="noopener">Gemini 3.5 Pro が延期か</a></div>'
        )
        expect(xml_decoded).to include('<div class="news-meta">(2026-07-17 / 財経新聞)</div>')
      end

      it "escapes markup in the source text so it does not become real tags" do
        malicious = "## 生成AI\n### [<dialog>要素](https://example.com/a)\n   本文\n"
        xml_decoded = CGI.unescapeHTML(render(malicious))

        expect(xml_decoded).to include("&lt;dialog&gt;")
        expect(xml_decoded).not_to include("<dialog>")
      end
    end

    # 旧フォーマット・崩れ（## 見出しが無い）は生テキスト整形へフォールバックする。
    context "with the old/unparseable format (fallback path)" do
      it "escapes used_news so it survives XML-decode-then-HTML-parse without becoming markup" do
        xml_decoded = CGI.unescapeHTML(render("・<dialog>要素の新機能\n   https://example.com/a\n"))

        expect(xml_decoded).to include("&lt;dialog&gt;")
        expect(xml_decoded).not_to include("<dialog>")
      end

      it "preserves line breaks as <br> after both decode steps" do
        xml_decoded = CGI.unescapeHTML(render("1行目\n2行目\n"))

        expect(xml_decoded).to include("1行目<br>")
        expect(xml_decoded).to include("2行目<br>")
      end

      it "turns URLs into anchor tags after both decode steps" do
        xml_decoded = CGI.unescapeHTML(render("参考: https://example.com/a\n"))

        expect(xml_decoded).to include('<a href="https://example.com/a">https://example.com/a</a>')
      end
    end

    it "leaves content empty when used_news is blank" do
      expect(render("")).to eq("")
    end
  end

  describe ".episode_object_names" do
    it "expands an mp3 filename to all sibling files that make up one episode" do
      names = described_class.episode_object_names("miyamai_news_20260714_afternoon.mp3")

      expect(names).to eq([
        "miyamai_news_20260714_afternoon.mp3",
        "miyamai_news_20260714_afternoon.used.txt",
        "miyamai_news_20260714_afternoon.transcript.txt"
      ])
    end
  end

  describe "#render_html and #render_feed" do
    # 番組名を PROGRAM_NAME の実値と別の文字列に差し替えて描画する。テンプレートが
    # 定数を参照せずリテラルをハードコードしていると、この値が反映されず検出できる。
    let(:program_name) { "テスト番組名XYZ" }
    let(:publisher) { build_publisher }
    let(:rows) do
      [["2026-07-14", "miyamai_news_20260714_afternoon.mp3", "回タイトル 2026-07-14", "", "2026-07-14T00:00:00Z"]]
    end

    before { stub_const("Publisher::PROGRAM_NAME", program_name) }

    it "renders PROGRAM_NAME into index.html's <title>/<link title>/<h1> instead of a hardcoded string" do
      html = publisher.send(:render_html, rows)

      expect(html).to include("<title>#{program_name}</title>")
      expect(html).to include(%(title="#{program_name}"))
      expect(html).to include("<h1>#{program_name}</h1>")
    end

    it "renders PROGRAM_NAME into feed.xml's <title> instead of a hardcoded string" do
      xml = publisher.send(:render_feed, rows)

      expect(xml).to include("<title>#{program_name}</title>")
    end

    it "omits the push notification button when web_push is not configured" do
      html = publisher.send(:render_html, rows)

      expect(html).not_to include("pushsubscribe")
    end

    it "renders the push notification button and subscribe script when web_push is configured" do
      allow(Config).to receive(:web_push).and_return(double("web_push", vapid_public_key: "test-key"))

      html = publisher.send(:render_html, rows)

      expect(html).to include("pushsubscribe")
      expect(html).to include("navigator.serviceWorker.register('/sw.js')")
      expect(html).to include('"test-key"')
    end
  end
end
