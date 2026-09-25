# frozen_string_literal: true

require "internal/object_storage"

# R2Storage と同じ操作を Hash 上で行うテスト用ストレージ。
class InMemoryStorage
  attr_reader :objects

  def initialize(objects = {})
    @objects = objects.dup
  end

  def put(key, body, content_type:, cache_control: nil)
    @objects[key] = body.respond_to?(:read) ? body.read : body
  end

  def put_file(key, path, content_type:, cache_control: nil)
    put(key, File.binread(path), content_type:, cache_control:)
  end

  def get(key)
    @objects.fetch(key) { raise Internal::ObjectStorage::ObjectNotFound, "object not found: #{key}" }
  end

  def exist?(key) = @objects.key?(key)

  def list(prefix) = @objects.keys.select { |k| k.start_with?(prefix) }.sort

  def delete(key)
    @objects.delete(key)
  end

  def move(from_key, to_key)
    return :already_moved if !exist?(from_key) && exist?(to_key)

    @objects[to_key] = @objects.delete(from_key) { raise Internal::ObjectStorage::ObjectNotFound, from_key }
    :moved
  end
end
