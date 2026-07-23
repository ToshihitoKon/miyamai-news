# frozen_string_literal: true

module Internal
  module Notifiers
    # 文字列の配列（block、通常は記事1本分の全文）を、プラットフォームごとの文字数上限
    # 以内のチャンクに分割する。全文投稿の方針（要約しない、CLAUDE.md「Notifier」参照）
    # を実装で支えるため、戻り値のチャンクを順に連結すれば入力全体を復元できる
    # （情報欠落なしを保証する）。
    #
    # 記事1本の内容（メインの3行入れ子要約＋メタ情報）が単体で上限を超えるケースが
    # あるため、2段階で分割する: block単位の貪欲な詰め込み（#pack）と、単体で上限を
    # 超える block の行単位フォールバック分割（#pack_block）。
    module Chunker
      module_function

      # 文字数は String#length（コードポイント数）で数える。bytesize で数えると
      # 日本語部分が想定より早く上限に達し、意図せず過剰分割されるため。
      def pack(blocks, limit:, separator: "\n\n")
        pieces = blocks.flat_map { |block| pack_block(block, limit: limit) }
        greedy_join(pieces, limit: limit, separator: separator)
      end

      # 1 block（1記事分の raw_lines 連結など）を、それ単体で limit に収まるなら
      # 単一要素の配列、超えるなら行単位で複数チャンクに分割した配列で返す。1行自体が
      # limit を超える極端なケース（長大URL等）は文字単位の断片（#slice_line）に
      # まで分解してから積む。
      def pack_block(block, limit:)
        return [block] if block.length <= limit

        lines = block.each_line.flat_map { |raw_line| slice_line(raw_line.chomp, limit) }
        greedy_join(lines, limit: limit, separator: "\n")
      end

      # 断片（piece）を、隣り合うものが limit に収まる限り separator で連結しながら
      # 貪欲に詰める。current.empty? では「まだ何も積んでいない」と「空文字列の
      # piece（空行）だけを積んだ」を区別できず空行を取りこぼすため、蓄積済みかどうかは
      # 配列の有無で別途判定する。
      def greedy_join(pieces, limit:, separator:)
        chunks = []
        current = []

        pieces.each do |piece|
          candidate = (current + [piece]).join(separator)
          if current.empty? || candidate.length <= limit
            current << piece
          else
            chunks << current.join(separator)
            current = [piece]
          end
        end
        chunks << current.join(separator) unless current.empty?
        chunks
      end

      # 1行を limit 文字以下の断片に文字単位で分割する（空行はそのまま [""] を返す）。
      def slice_line(line, limit)
        return [line] if line.length <= limit

        line.chars.each_slice(limit).map(&:join)
      end
    end
  end
end
