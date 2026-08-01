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
    INDEX_OBJECT = "index.html"

    # 生成ページとして配信するオブジェクト。これ以外はエピソード資材として扱う。
    PAGE_OBJECTS = [INDEX_OBJECT, "feed.xml", "manifest.json"].freeze

    LEDGER_OBJECT = "archives.csv"

    ASSET_CACHE_CONTROL = "public, max-age=3600"

    DeployFailed = Class.new(StandardError)
    LedgerMissing = Class.new(StandardError)

    def self.from_config
      cf = ::Config.cloudflare
      new(
        public_base: cf.public_base,
        retention_episodes: cf.retention_episodes,
        storage: R2Storage.new(
          bucket: cf.bucket, account_id: cf.account_id, episode_prefix: cf.episode_prefix
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

      "#{@public_base}/#{@storage.episode_key(object)}"
    end

    def page_url(object)
      return "#{@public_base}/" if object == INDEX_OBJECT

      "#{@public_base}/#{object}"
    end

    # 画像などの恒久素材。R2 に置くのでリポジトリにも配信物にも実体を持たない。
    def asset_url(object) = "#{@public_base}/#{@storage.asset_key(object)}"

    def upload_asset(object, path, content_type:)
      @storage.put_file(@storage.asset_key(object), path,
        content_type: content_type, cache_control: ASSET_CACHE_CONTROL)
    end

    def asset_exist?(object) = @storage.exist?(@storage.asset_key(object))

    # --- 安定 ID -----------------------------------------------------------

    # RFC 4151 の tag URI。
    def tag_uri(date, specific) = "tag:#{tag_authority},#{date}:#{specific}"

    def tag_authority = URI.parse(@public_base).host

    # --- エピソード資材 ----------------------------------------------------

    # ローカルファイルをそのまま送る（mp3・transcript のような実体があるもの）。
    def upload_episode_file(object, path, content_type:, cache_control: nil)
      @storage.put_file(@storage.episode_key(object), path,
        content_type: content_type, cache_control: cache_control)
    end

    # メモリ上で組み立てた内容を書き込む（used.txt・used.html のような生成物）。
    def write_episode_file(object, content, content_type:, cache_control: nil)
      @storage.put(@storage.episode_key(object), content,
        content_type: content_type, cache_control: cache_control)
    end

    def episode_file_exist?(object) = @storage.exist?(@storage.episode_key(object))

    # 退避先は資材プレフィックスの外。
    def retire_episode_file(object)
      @storage.move(@storage.episode_key(object), @storage.archive_key(object))
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

    def deploy(dir)
      write_delivery_headers(dir)
      deployer.call(dir) || raise(DeployFailed, "site deploy failed for #{dir}")
    end

    private

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
