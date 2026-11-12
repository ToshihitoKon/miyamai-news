# frozen_string_literal: true

require "fileutils"

class TtsReadingCheck
  module Transcript
    class Error < StandardError; end

    LINE_PATTERN = /\A\s*(?:[-*・]\s*)?(?:\*\*)?(\d+)(?:\*\*)?\s*[:.](?:\*\*)?\s*(.*?)\s*\z/
    IGNORABLE_LINE = /\A(?:```.*)?\z/
    EXCERPT_LENGTH = 200

    module_function

    def parse(output, expected_count)
      raise Error, "transcript is not valid UTF-8 (fix it by hand and save it as UTF-8)" unless output.valid_encoding?

      by_number = {}
      unexpected = []
      duplicated = []
      output.delete_prefix("\uFEFF").unicode_normalize(:nfkc).each_line do |line|
        match = LINE_PATTERN.match(line)
        number = match && match[1].to_i
        if number&.between?(1, expected_count)
          duplicated << number if by_number.key?(number)
          by_number[number] = match[2]
        else
          stripped = line.strip
          unexpected << stripped unless by_number.empty? || IGNORABLE_LINE.match?(stripped)
        end
      end

      raise Error, "transcript has no numbered lines: #{excerpt(output)}" if by_number.empty?
      raise Error, "transcript has duplicate line numbers: #{duplicated.uniq.join(',')}" unless duplicated.empty?
      raise Error, "transcript has unexpected lines after the first numbered line: #{unexpected.first(3).join(' / ')}" unless unexpected.empty?

      missing = (1..expected_count).reject { |number| by_number.key?(number) }
      raise Error, "transcript is missing line numbers: #{missing.join(',')}" unless missing.empty?

      (1..expected_count).map { |number| by_number[number] }
    end

    def excerpt(output)
      text = output.strip.gsub(/\s+/, " ")
      return "(empty output)" if text.empty?

      text.length > EXCERPT_LENGTH ? "#{text[0, EXCERPT_LENGTH]}…" : text
    end

    def save_raw(output_path, inputs_path, output:, inputs:)
      FileUtils.rm_f(inputs_path)
      File.write(output_path, output)
      File.write(inputs_path, inputs.join("\n"))
    end

    def load_raw_matching(output_path, inputs_path, inputs)
      return nil unless File.exist?(output_path) && File.exist?(inputs_path)
      return nil unless File.read(inputs_path).split("\n") == inputs

      File.read(output_path)
    end
  end
end
