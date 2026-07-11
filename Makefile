# 宮舞モカ ニュース番組パイプライン
#
#   make generate  … 台本生成 → 音声合成 → BGM 合成。成果物は dist/ へ
#   make upload    … dist/ の該当回 mp3(+used.txt)を GCS へアップロード
#   make clean     … work/ を削除し、GCS にアップロード済みの成果物を dist/ から削除
#
# 日付を指定する場合: make upload DATE=20260710
# 時間帯を指定する場合: make upload SLOT=morning  (morning/afternoon/evening)
# BGM を差し替える場合: make generate BGM=path/to/bgm.mp3

RUBY   ?= ruby
# バケット名は config.yaml (gcs.bucket) を正とする。BUCKET=... で上書きも可能。
BUCKET ?= $(shell $(RUBY) -ryaml -e 'puts YAML.safe_load_file("config.yaml").dig("gcs","bucket")' 2>/dev/null)
DATE   ?= $(shell date +%Y%m%d)
# 現在時刻から時間帯 slot を決める。miyamai_news.rb の slot_for と同じ境界:
# morning=0〜11時 / afternoon=12〜17時 / evening=18時〜。
# 別の回をアップロードするときは SLOT=... で上書きする。
SLOT   ?= $(shell h=$$(date +%H); if [ $$h -lt 12 ]; then echo morning; elif [ $$h -lt 18 ]; then echo afternoon; else echo evening; fi)
BGM    ?=

DIST      := dist
WORK      := work
MP3       := $(DIST)/miyamai_news_$(DATE)_$(SLOT).mp3
USED      := $(DIST)/miyamai_news_$(DATE)_$(SLOT).used.txt
GCS_MP3   := gs://$(BUCKET)/miyamai_news_$(DATE)_$(SLOT).mp3

.PHONY: generate upload clean help

help:
	@echo "make generate [BGM=...]          台本→音声→BGM合成。成果物は $(DIST)/"
	@echo "make upload   [DATE=... SLOT=...] $(DIST)/ の該当回を GCS へアップロード"
	@echo "make clean                       work/ を削除し、アップロード済み成果物を $(DIST)/ から削除"

generate:
	$(RUBY) miyamai_news.rb $(BGM)

upload:
	@test -f "$(MP3)" || { echo "mp3 が見つかりません: $(MP3) (make generate 済み? DATE=$(DATE) SLOT=$(SLOT) は正しい?)"; exit 1; }
	$(RUBY) publish.rb "$(MP3)" "$(BUCKET)"

# work/ の中間キャッシュを削除する。ただし last_fetch.txt は残す
# （前回収集時刻の記録。消すと収集 window が上限にリセットされ、次回に
#  過去分を拾い直して重複してしまう）。dist/ 内の各 mp3 は GCS 上に同名が
# 存在する場合のみ削除する（未アップロードの回を誤って消さないため）。
# used.txt は対の mp3 とセットで扱う。ディレクトリ自体は .gitkeep で残す。
clean:
	@find $(WORK) -mindepth 1 -maxdepth 1 ! -name last_fetch.txt ! -name .gitkeep -exec rm -rf {} +
	@for mp3 in $(DIST)/miyamai_news_*.mp3; do \
		[ -e "$$mp3" ] || continue; \
		obj="gs://$(BUCKET)/$$(basename $$mp3)"; \
		if gcloud storage ls "$$obj" >/dev/null 2>&1; then \
			echo "アップロード済み → 削除: $$mp3"; \
			rm -f "$$mp3" "$${mp3%.mp3}.used.txt"; \
		else \
			echo "未アップロード → 保持: $$mp3"; \
		fi; \
	done
