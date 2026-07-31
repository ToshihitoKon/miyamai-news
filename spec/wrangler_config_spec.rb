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

  it "routes R2-backed prefixes and the web push endpoints to the worker" do
    expect(wrangler.dig("assets", "run_worker_first"))
      .to contain_exactly("/episodes/*", "/assets/*", "/subscribe", "/notify")
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

  # directory があると素の `wrangler deploy` が通ってしまい、そのディレクトリの
  # 中身で公開サイト全体が置き換わる（デプロイはバージョン単位なので、生成済みの
  # index.html / feed.xml が消える）。未設定なら wrangler がエラーで止まる。
  it "omits assets.directory so a bare deploy cannot replace the site" do
    expect(wrangler["assets"]).not_to have_key("directory")
  end

  it "binds the worker to an R2 bucket as EPISODES" do
    expect(wrangler["r2_buckets"].map { |b| b["binding"] }).to include("EPISODES")
  end

  it "binds the worker to a D1 database as SUBSCRIPTIONS" do
    expect(wrangler["d1_databases"].map { |d| d["binding"] }).to include("SUBSCRIPTIONS")
  end

  # web-push npm が VAPID 署名・ペイロード暗号化に Node 標準の crypto/buffer を
  # 使うため、Workers の nodejs_compat が無いと動かない。
  it "enables nodejs_compat for the web-push package" do
    expect(wrangler["compatibility_flags"]).to include("nodejs_compat")
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
