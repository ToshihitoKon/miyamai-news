# frozen_string_literal: true

module Internal
  # オブジェクトストレージ実装が共通で使う例外。呼び出し側が特定の
  # ストレージ（S3/R2 等）の例外型に依存しないようにする。
  module ObjectStorage
    ObjectNotFound = Class.new(StandardError)
  end
end
