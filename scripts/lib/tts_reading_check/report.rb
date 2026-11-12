# frozen_string_literal: true

require_relative "../../../lib/internal/relative_path"

class TtsReadingCheck
  module Report
    module_function

    def render(tts_script_path:, generated_at:, chunk_texts:, transcripts:, wav_paths:, findings:, reused_batch_count:, batch_count:)
      findings_by_chunk = findings.group_by(&:chunk_number).sort_by(&:first)
      empty_numbers = transcripts.each_index.select { |i| transcripts[i].strip.empty? }.map { |i| i + 1 }
      header = [
        "- 対象: #{Internal::RelativePath.from_root(tts_script_path)}",
        "- 実行日時: #{generated_at.strftime('%Y-%m-%d %H:%M %z')}",
        "- チャンク数: #{chunk_texts.size}",
        "- 読み間違いの疑い: #{findings.size} 件（#{findings_by_chunk.size} チャンク" \
        "#{transcription_count_note(findings.count(&:transcription?))}）",
        "- 書き起こしが空のチャンク: #{empty_numbers.empty? ? 'なし' : empty_numbers.join(', ')}",
        "- 書き起こし: #{reuse_sentence(reused_batch_count, batch_count)}"
      ]
      body =
        if findings_by_chunk.empty?
          [no_findings_sentence(empty_numbers)]
        else
          findings_by_chunk.map do |number, chunk_findings|
            chunk_section(number, chunk_findings,
              text: chunk_texts[number - 1], transcript: transcripts[number - 1], wav_path: wav_paths[number - 1])
          end
        end

      "#{[header.join("\n"), *body].join("\n\n")}\n"
    end

    def transcription_count_note(count)
      count.zero? ? "" : "、うち書き起こしの揺れの可能性が高いもの #{count} 件"
    end

    def reuse_sentence(reused_batch_count, batch_count)
      return "保存済みのものを使い回した" if reused_batch_count == batch_count
      return "今回取り直した" if reused_batch_count.zero?

      "#{batch_count} 回に分けたうち #{reused_batch_count} 回分は保存済みのものを使い回した"
    end

    def no_findings_sentence(empty_numbers)
      return "読み間違いの疑いはありませんでした。" if empty_numbers.empty?

      "読み間違いの疑いはありませんでしたが、書き起こしが空のチャンクは判定できていません。"
    end

    def chunk_section(number, findings, text:, transcript:, wav_path:)
      suspicions = findings.map do |finding|
        "  - #{or_none(finding.word)}: 期待 #{or_none(finding.expected)} / 聞こえた #{or_none(finding.heard)}" \
          "#{transcription_note(finding)}"
      end
      [
        "## チャンク #{number}",
        "",
        "- 本文: #{text}",
        "- 書き起こし: #{transcript}",
        "- 疑い",
        *suspicions,
        "- wav: #{Internal::RelativePath.from_root(wav_path)}"
      ].join("\n")
    end

    def transcription_note(finding)
      return "" unless finding.transcription?
      return "（書き起こしの揺れの可能性が高い）" if finding.reason.strip.empty?

      "（書き起こしの揺れの可能性が高い: #{or_none(finding.reason)}）"
    end

    def or_none(value) = value.strip.empty? ? "（なし）" : value.gsub(/\s*\n\s*/, " ")
  end
end
