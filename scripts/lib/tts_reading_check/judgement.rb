# frozen_string_literal: true

require "json"

class TtsReadingCheck
  module Judgement
    class Error < StandardError; end

    MISREADING = "misreading"
    TRANSCRIPTION = "transcription"

    Finding = Data.define(:chunk_number, :word, :expected, :heard, :cause, :reason) do
      def initialize(cause: MISREADING, reason: "", **fields) = super(cause:, reason:, **fields)

      def transcription? = cause == TRANSCRIPTION
    end

    NO_FINDINGS_OUTPUT = /\A\s*(?:```(?i:json)?\s*)?\[\s*\]\s*(?:```\s*)?\z/

    module_function

    def parse(output, chunk_count)
      raise Error, "judgement output is not valid UTF-8" unless output.valid_encoding?
      return [] if NO_FINDINGS_OUTPUT.match?(output)

      extract_array(output).map { |element| build_finding(element, chunk_count) }
    end

    def extract_array(output)
      candidates = finding_arrays(output)
      outermost = candidates.reject do |candidate|
        candidates.any? { |other| !other.equal?(candidate) && other[:range].cover?(candidate[:range]) }
      end
      raise Error, "judgement output has no JSON array of finding objects" if outermost.empty?
      raise Error, "judgement output has #{outermost.size} separate JSON arrays of finding objects" if outermost.size > 1

      array = outermost.first[:array]
      raise Error, "judgement output has [] among other text" if array.empty?

      array
    end

    def finding_arrays(output)
      opens = char_indices(output, "[")
      closes = char_indices(output, "]")
      opens.product(closes).filter_map do |first, last|
        next if last < first

        parsed = JSON.parse(output[first..last])
        { range: first..last, array: parsed } if parsed.all?(Hash)
      rescue JSON::ParserError
        nil
      end
    end

    def char_indices(text, char) = text.each_char.with_index.filter_map { |c, i| i if c == char }

    def build_finding(element, chunk_count)
      chunk = Integer(element["chunk"].to_s, 10, exception: false)
      raise Error, "judgement chunk is not in 1..#{chunk_count}: #{element['chunk'].inspect}" unless chunk&.between?(1, chunk_count)

      cause = element["cause"] == TRANSCRIPTION ? TRANSCRIPTION : MISREADING
      Finding.new(chunk_number: chunk, word: element["word"].to_s, expected: element["expected"].to_s,
        heard: element["heard"].to_s, cause:, reason: element["reason"].to_s)
    end
  end
end
