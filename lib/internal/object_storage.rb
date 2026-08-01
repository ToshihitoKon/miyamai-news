# frozen_string_literal: true

module Internal
  # オブジェクトストレージ実装が共通で使う例外。
  module ObjectStorage
    ObjectNotFound = Class.new(StandardError)
  end
end
