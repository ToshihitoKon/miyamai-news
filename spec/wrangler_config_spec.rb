# frozen_string_literal: true

require "spec_helper"
require "json"
require "internal/config"
require "internal/r2_storage"

# wrangler.jsonc と config.yaml は同じ前提（資材プレフィックス・公開ホスト）を
# 別々に持っている。片方だけ変えると本番でしか気づけない壊れ方をするので、
# ここで一致を固定する。
RSpec.describe "wrangler.jsonc" do
  let(:wrangler) do
    path = File.expand_path("../wrangler.jsonc", __dir__)
    # JSONC のコメントを落としてから解析する（文字列内の // は対象外）。
    stripped = File.read(path).gsub(%r{^\s*//.*$}, "")
    JSON.parse(stripped)
  end

  it "routes both R2-backed prefixes to the worker" do
    expect(wrangler.dig("assets", "run_worker_first")).to contain_exactly("/episodes/*", "/assets/*")
  end

  # run_worker_first と episode_prefix がずれると、mp3 が static assets 側に
  # ルーティングされて 404 になる。
  it "keeps run_worker_first in sync with the sample config's episode_prefix" do
    sample = YAML.safe_load_file(File.expand_path("../config.sample.yaml", __dir__))
    prefix = sample.dig("cloudflare", "episode_prefix")

    expect(wrangler.dig("assets", "run_worker_first")).to include("/#{prefix}/*")
  end

  # 画像は R2 の assets/ にあるので、Worker が通らないと配信されない。
  it "routes the asset prefix used by Site" do
    expect(wrangler.dig("assets", "run_worker_first"))
      .to include("/#{Internal::R2Storage::ASSET_PREFIX}/*")
  end

  it "binds the worker to an R2 bucket as EPISODES" do
    expect(wrangler["r2_buckets"].map { |b| b["binding"] }).to include("EPISODES")
  end

  it "declares a custom domain route" do
    route = wrangler["routes"].first

    expect(route["custom_domain"]).to be true
    expect(route["pattern"]).to be_a(String)
  end

  it "points main at the worker script that serves R2" do
    expect(File.exist?(File.expand_path("../#{wrangler['main']}", __dir__))).to be true
  end
end
