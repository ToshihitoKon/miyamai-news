# frozen_string_literal: true

require "fileutils"
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

  def sync_down(prefix:, root:)
    FileUtils.rm_rf(File.join(root, prefix))
    FileUtils.mkdir_p(File.join(root, prefix))
    list(prefix).each do |key|
      path = File.join(root, key)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, @objects[key])
    end
  end

  def sync_up(prefix:, root:)
    local_dir = File.join(root, prefix)
    local_keys = Dir.glob("**/*", base: local_dir).select { |rel| File.file?(File.join(local_dir, rel)) }.map do |rel|
      @objects[prefix + rel] = File.binread(File.join(local_dir, rel))
      prefix + rel
    end
    (list(prefix) - local_keys).each { |key| @objects.delete(key) }
  end
end
