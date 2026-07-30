# frozen_string_literal: true

require "uri"
require_relative "config"
require_relative "object_storage"
require_relative "r2_storage"

module Internal
  # 公開されている番組サイトそのものを表す。成果物の置き場所・公開 URL・
  # 保持件数・サイトの反映をまとめて受け持つ。
  # Publisher はこのインターフェース越しにだけサイトを触り、ストレージの種類や
  # キー構成・デプロイ手段を知らない。
  class Site
    # 生成ページとして配信するオブジェクト。これ以外はエピソード資材として扱う。
    PAGE_OBJECTS = ["index.html", "feed.xml", "manifest.json"].freeze

    LEDGER_OBJECT = "archives.csv"

    DeployFailed = Class.new(StandardError)
    LedgerMissing = Class.new(StandardError)

    def self.from_config
      cf = ::Config.cloudflare
      new(
        public_base: cf.public_base,
        retention_episodes: cf.retention_episodes,
        storage: R2Storage.new(
          bucket: cf.bucket, account_id: cf.account_id, audio_prefix: cf.audio_prefix
        )
      )
    end

    def initialize(public_base:, retention_episodes:, storage:, deployer: nil)
      @public_base = public_base
      @retention_episodes = retention_episodes
      @storage = storage
      @deployer = deployer
    end

    attr_reader :retention_episodes

    # --- 公開 URL ----------------------------------------------------------

    # 生成ページはサイト直下、エピソード資材は資材用プレフィックス配下を指す。
    # 再生ページの JS が mp3 URL の拡張子だけを差し替えて .used.html /
    # .transcript.txt を引くため、mp3 とその派生物は同じ階層に並ぶ。
    def url_for(object)
      return page_url(object) if PAGE_OBJECTS.include?(object)

      "#{@public_base}/#{@storage.audio_key(object)}"
    end

    def page_url(object) = "#{@public_base}/#{object}"

    # --- 安定 ID -----------------------------------------------------------

    # RFC 4151 の tag URI。配信 URL から独立しているので、ドメインやパスを
    # 変えても購読者側の重複判定キーが動かない。
    # authority には発行日時点で管理していたドメインを使う。
    def tag_uri(date, specific) = "tag:#{tag_authority},#{date}:#{specific}"

    def tag_authority = URI.parse(@public_base).host

    # --- エピソード資材 ----------------------------------------------------

    # ローカルファイルをそのまま送る（mp3・transcript のような実体があるもの）。
    def upload_episode_file(object, path, content_type:, cache_control: nil)
      @storage.put_file(@storage.audio_key(object), path,
        content_type: content_type, cache_control: cache_control)
    end

    # メモリ上で組み立てた内容を書き込む（used.txt・used.html のような生成物）。
    def write_episode_file(object, content, content_type:, cache_control: nil)
      @storage.put(@storage.audio_key(object), content,
        content_type: content_type, cache_control: cache_control)
    end

    def episode_file_exist?(object) = @storage.exist?(@storage.audio_key(object))

    # 退避先は資材プレフィックスの外。中に置くと公開経路に残り、保持件数を
    # 超えた回が読めるままになる。
    def retire_episode_file(object)
      @storage.move(@storage.audio_key(object), @storage.archive_key(object))
    end

    def purge_retired = @storage.delete_prefix(@storage.archive_prefix)

    # --- 台帳 --------------------------------------------------------------

    def ledger_exist? = @storage.exist?(LEDGER_OBJECT)

    def read_ledger
      @storage.get(LEDGER_OBJECT)
    rescue ObjectStorage::ObjectNotFound => e
      raise LedgerMissing, e.message
    end

    def write_ledger(csv)
      @storage.put(LEDGER_OBJECT, csv, content_type: "text/csv")
    end

    # --- サイトの反映 ------------------------------------------------------

    # 反映はディレクトリ単位で、ここに無いファイルは公開サイトから消える。
    def deploy(dir)
      write_delivery_headers(dir)
      deployer.call(dir) || raise(DeployFailed, "site deploy failed for #{dir}")
    end

    private

    # feed.xml の Content-Type は拡張子ベースだと application/xml 系になるため
    # 明示的に上書きする。資材プレフィックス配下（Worker が返す経路）には
    # このファイルが適用されないので、そちらは Worker 側でヘッダーを付ける。
    def write_delivery_headers(dir)
      File.write(File.join(dir, "_headers"), <<~HEADERS)
        /index.html
          Cache-Control: public, max-age=300
        /feed.xml
          Cache-Control: public, max-age=300
          Content-Type: application/atom+xml; charset=utf-8
      HEADERS
    end

    def deployer
      @deployer ||= ->(dir) { system("wrangler", "deploy", "--assets", dir) }
    end
  end
end
