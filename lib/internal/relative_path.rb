# frozen_string_literal: true

require_relative "config"

module Internal
  module RelativePath
    module_function

    def from_root(path)
      path.delete_prefix("#{::Config::ROOT_DIR}/")
    end
  end
end
