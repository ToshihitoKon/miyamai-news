# frozen_string_literal: true

module Internal
  # arXiv フィード固有の知識を隔離する。
  module Arxiv
    class << self
      # link が arXiv の abs リンクで、投稿月の月末を基準に max_age_days 以上前と
      # 判定できれば true。abs リンクでなければ false（判定対象外）。
      def old?(link, max_age_days:, now:)
        yymm = link[%r{arxiv\.org/abs/(\d{4})\.\d+}, 1]
        return false unless yymm

        cutoff = now - (max_age_days * 86_400)
        posted_month_end(yymm) < cutoff
      end

      private

      # ID からは投稿年月までしかわからないため、その月の最終日を投稿日とみなす
      # （同月内の記事を誤って古い判定にしないための安全側の丸め）。
      def posted_month_end(yymm)
        year = 2000 + yymm[0..1].to_i
        month = yymm[2..3].to_i
        next_month_start = Time.new(year, month, 1) + (32 * 86_400)
        Time.new(next_month_start.year, next_month_start.month, 1) - 1
      end
    end
  end
end
