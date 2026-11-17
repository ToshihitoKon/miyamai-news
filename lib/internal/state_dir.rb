# frozen_string_literal: true

# 実行をまたいで保持するパイプラインの内部状態を置くディレクトリ（work/state/）。
# 中身はそのまま R2 の state/ と同期される。
module StateDir
  module_function

  NAME = "state"

  def path(work_dir) = File.join(work_dir, NAME)
end
