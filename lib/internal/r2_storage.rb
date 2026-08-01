# frozen_string_literal: true

require "aws-sdk-s3"
require_relative "object_storage"

module Internal
  # R2（S3 互換 API）上のオブジェクト操作をまとめる。
  # Publisher からストレージ操作の詳細を隠し、S3 クライアントを差し替え可能にする。
  class R2Storage
    include ObjectStorage

    # 退避先プレフィックス。episode_prefix の外に置く。
    ARCHIVE_PREFIX = "archived"

    # 画像などの恒久素材。エピソードと違い retention の退避対象にしない。
    ASSET_PREFIX = "assets"

    def initialize(bucket:, account_id: nil, client: nil, episode_prefix: "episodes")
      @bucket = bucket
      @episode_prefix = episode_prefix
      @account_id = account_id
      @client = client
    end

    attr_reader :bucket, :episode_prefix

    # エピソード関連ファイル（mp3 / used / transcript）の R2 キー。
    # 再生ページの JS が mp3 URL の拡張子だけを差し替えて兄弟ファイルを引くため、
    # 同一プレフィックス配下に揃える。
    def episode_key(object) = "#{@episode_prefix}/#{object}"

    def archive_key(object) = "#{ARCHIVE_PREFIX}/#{object}"

    def archive_prefix = "#{ARCHIVE_PREFIX}/"

    def asset_key(object) = "#{ASSET_PREFIX}/#{object}"

    def put(key, body, content_type:, cache_control: nil)
      params = { bucket: @bucket, key: key, body: body, content_type: content_type }
      params[:cache_control] = cache_control if cache_control
      client.put_object(**params)
    end

    def put_file(key, path, content_type:, cache_control: nil)
      File.open(path, "rb") do |f|
        put(key, f, content_type: content_type, cache_control: cache_control)
      end
    end

    def get(key)
      client.get_object(bucket: @bucket, key: key).body.read
    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
      raise ObjectNotFound, "object not found: #{key}"
    end

    def exist?(key)
      client.head_object(bucket: @bucket, key: key)
      true
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      false
    end

    def move(from_key, to_key)
      return :already_moved if !exist?(from_key) && exist?(to_key)

      client.copy_object(bucket: @bucket, key: to_key,
        copy_source: "#{@bucket}/#{from_key}")
      client.delete_object(bucket: @bucket, key: from_key)
      :moved
    end

    def list(prefix)
      keys = []
      token = nil
      loop do
        res = client.list_objects_v2(bucket: @bucket, prefix: prefix, continuation_token: token)
        keys.concat(res.contents.map(&:key))
        break unless res.is_truncated

        token = res.next_continuation_token
      end
      keys
    end

    # DeleteObjects は 1 リクエスト最大 1000 キー。
    def delete_prefix(prefix)
      keys = list(prefix)
      return 0 if keys.empty?

      keys.each_slice(1000) do |batch|
        client.delete_objects(bucket: @bucket,
          delete: { objects: batch.map { |k| { key: k } } })
      end
      keys.size
    end

    private

    # 認証情報の要求は最初のリクエストまで遅らせる。
    def client
      @client ||= Aws::S3::Client.new(
        access_key_id: fetch_env("R2_ACCESS_KEY_ID"),
        secret_access_key: fetch_env("R2_SECRET_ACCESS_KEY"),
        endpoint: "https://#{@account_id}.r2.cloudflarestorage.com",
        region: "auto"
      )
    end

    def fetch_env(name)
      ENV[name] or raise KeyError, "missing environment variable: #{name}"
    end
  end
end
