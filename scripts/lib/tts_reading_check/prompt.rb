# frozen_string_literal: true

require "erb"

class TtsReadingCheck
  module Prompt
    DIR = File.join(__dir__, "templates")
    TRANSCRIBE = "transcribe.prompt"
    JUDGE = "judge.prompt"

    module_function

    def path(name) = File.join(DIR, "#{name}.erb")

    def render(name, **locals) = ERB.new(File.read(path(name)), trim_mode: "-").result_with_hash(locals)
  end
end
