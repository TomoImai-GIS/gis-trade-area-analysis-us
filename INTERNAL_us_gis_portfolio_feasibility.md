# US版 GIS Trade Area Analysis — Feasibility Study まとめ

> このドキュメントは、既存の日本向けGISポートフォリオ（`gis-trade-area-analysis`）のアメリカ版を  
> 新規作成する際の事前調査・実現性検討の記録です。Claude Codeでの実装着手前の引き継ぎ資料として使用してください。

---

## 1. 背景・目的

- **既存リポジトリ**：[TomoImai-GIS/gis-trade-area-analysis](https://github.com/TomoImai-GIS/gis-trade-area-analysis)
  - PostgreSQL + PostGIS + Python による日本向け空間分析ツールキット
  - 国土数値情報（行政界ポリゴン）＋ e-Stat 国勢調査データ（2015/2020）を使用
  - SQLテンプレート15本 ＋ Pythonユーティリティで構成
- **目的**：Upworkでの海外案件獲得を見据え、同等のアメリカ版ポートフォリオを作成する
- **実装方法**：Claude Codeを使って進める

---

## 2. アメリカにおける公的データソース

日本のe-Stat・国土数値情報に相当するデータは、以下の公的機関から無償取得可能。

### 2-1. U.S. Census Bureau（国勢調査局）← 主要機関

| 用途 | データ名 | 説明 |
|---|---|---|
| 行政界ポリゴン | **TIGER/Line Shapefiles** | 州・郡（County）・市（Place）・Census Tract 等。国土数値情報に相当。 |
| 人口統計（10年ごと） | **Decennial Census** | 日本の国勢調査に相当 |
| 人口統計（毎年） | **American Community Survey (ACS)** | 1年推計・5年推計。人口・世帯・所得・年齢・人種等200変数以上 |
| データポータル | **data.census.gov** | e-Statに相当 |
| API | **Census API** | 無償・APIキー即日発行。Pythonライブラリ（`census`）で自動取得可 |

- TIGER/Line 取得先：`census.gov/geographies/mapping-files/time-series/geo/tiger-line-file.html`

### 2-2. その他

| 機関 | 用途 |
|---|---|
| **USGS（米国地質調査所）** | 地形・土地利用・自然地物。The National Mapが総合ポータル |
| **data.gov** | 連邦政府オープンデータ横断ポータル |
| **OpenStreetMap** | 道路ネットワーク（日本版と共通、そのまま流用可） |

### 2-3. 行政レベルの日米対応

| 日本 | アメリカ |
|---|---|
| 都道府県 | State |
| 市区町村 | County（郡）/ City, Place（市） |
| 大字・小字 | Census Tract / Block Group / Block |

- **County（3,143件）** が日本の市町村（1,917件）に最も近い行政単位
- Place（Incorporated Place）まで含めると30,000件以上

---

## 3. 実現性評価

### 3-1. 結論

**実現性：高い。データの品質・取得容易性・API充実度は日本版より有利な面が多い。**

### 3-2. SQLテンプレートの移植可否

| 現行機能 | 移植可否 | 備考 |
|---|---|---|
| 座標 → 市区町村 逆ジオコーディング | ✅ そのまま移植可 | County / Place に置換するだけ |
| 商圏人口集計（半径N km） | ✅ そのまま移植可 | ACS 5年推計で人口・世帯取得可 |
| 高齢化率ランキング | ✅ 移植可（より細粒度） | ACSに年齢コホートデータあり |
| 最寄りデポへの配送割当 | ✅ そのまま移植可 | |
| GPSログ沿線の自治体リスト | ✅ そのまま移植可 | |
| コロプレス図生成（QGIS） | ✅ 移植可 | QGISは共通 |

### 3-3. Pythonツールの移植可否

| 現行機能 | 移植可否 | 備考 |
|---|---|---|
| JISメッシュコード変換 | 🔄 FIPS Codeへ置換 | 構造は類似 |
| 平面直角座標系変換 | 🔄 US State Plane座標系へ置換 | `pyproj` で対応可 |
| データクレンジング | ✅ ほぼ流用可 | |
| フォーマット変換（CSV/GeoJSON/Shapefile） | ✅ そのまま流用可 | |
| QGIS自動化 | ✅ そのまま流用可 | |

### 3-4. アメリカ版ならではの上乗せ価値

**① Census API による完全自動データ取得パイプライン（日本版にない強み）**

```python
import census
c = census.Census("YOUR_API_KEY")  # 無償・即日発行
data = c.acs5.state_county(('NAME', 'B01003_001E'), '*', '*')
```

日本版ではe-Statからの手動ダウンロードが前提になりがちだが、
アメリカ版ではデータ取得の自動化パイプライン自体をリポジトリに含められる。

**② より豊富な人口統計変数**

ACSは所得・人種・教育・住宅など200以上の変数を持ち、ユースケースの幅が広がる。

**③ ビジネスリアリティ**

Upworkの主要発注者は米国企業。「アメリカのデータで動く」という点がクライアントへの直接的な説得力になる。

---

## 4. ポートフォリオとしてのメリット（Upwork案件獲得観点）

- GIS/Spatial Analysis案件の多くは米国・カナダ・オーストラリア発
- クライアントが「Census Bureau」「TIGER files」「ACS」を知っている前提で会話できる
- 「日本でやったことをアメリカのデータで再現できる」は汎用性・移植能力の証明になる
- PostGIS + Python スタックはグローバル標準であり、そのまま評価される
- 日本版と並べて公開することで「同一スタックで異なる地域に対応できる」という訴求力が生まれる

---

## 5. リポジトリ・フォルダ構成

### 5-1. フォルダ構成

```
gis-trade-area-analysis-us/
├── sql/
│   ├── 01_basic/            # County/Place逆ジオコーディング、FIPS検索、直線距離
│   ├── 02_analysis/         # 商圏人口（ACS）、County割当、ルート分析、デモグラフィックランキング
│   ├── 03_visualization/    # コロプレス（income, poverty rate, population density等）
│   └── 04_maintenance/      # スキーマ設計・インデックス再構築・メンテナンス系（非公開）
├── python/
│   ├── 00_data_pipeline/    # 将来の自動化・定期更新パイプライン用（温存）
│   ├── 01_data_analytics/   # 散布図・回帰（poverty vs income density等）
│   ├── 02_QGIS_automation/  # マルチレイヤー地図自動生成
│   ├── 03_data_cleansing/   # データ品質チェック・クレンジング
│   ├── 04_data_conversion/  # CSV/GeoJSON/Shapefile変換
│   ├── 05_data_import/      # ★TIGER/Line・ACS初回取込スクリプト（日本版05系に相当）
│   └── 99_snippets/
│       └── gis_utils/       # FIPS Code処理、State Plane CRS変換、Census APIラッパー
├── data/                    # サンプルCSV（TIGER/ACSサブセット）
├── output/
│   ├── sql/                 # SQL + QGISで生成したマップ出力例
│   └── python/              # Pythonスクリプトで生成したチャート・プロット
└── docs/
    ├── analysis/            # ポートフォリオ向け分析レポート・考察
    └── images/              # 図表・マップ画像
```

### 5-2. 公開／非公開の方針

| フォルダ／ファイル | public化後 | 備考 |
|---|---|---|
| `sql/01_basic/` | ✅ 公開 | |
| `sql/02_analysis/` | ✅ 公開 | |
| `sql/03_visualization/` | ✅ 公開 | |
| `sql/04_maintenance/` | 🔒 非公開 | `.gitignore` 登録済み。ローカルのみ管理 |
| `python/00_data_pipeline/` | ✅ 公開 | 将来の自動化用として温存 |
| `python/01_data_analytics/` | ✅ 公開 | |
| `python/02_QGIS_automation/` | ✅ 公開 | |
| `python/03_data_cleansing/` | ✅ 公開 | |
| `python/04_data_conversion/` | ✅ 公開 | |
| `python/05_data_import/` | ✅ 公開 | TIGER/Line・ACS取込スクリプト |
| `python/99_snippets/` | ✅ 公開 | |
| `data/` | ✅ 公開 | サンプルデータのみ（大容量ファイルは output 同様 .gitignore 対象） |
| `output/` | ✅ 公開 | PNG/CSV等の生成物は `.gitignore` で除外 |
| `docs/` | ✅ 公開 | ポートフォリオ向け資料 |
| `INTERNAL_*.md` | 🔒 非公開 | `.gitignore` 登録済み。public化前に `git rm --cached` で追跡解除が必要 |

> **注意**：`INTERNAL_us_gis_portfolio_feasibility.md` は現在コミット済みのため、  
> public化前に `git rm --cached INTERNAL_us_gis_portfolio_feasibility.md` を実行し、  
> コミットし直してから visibility を変更すること。

---

## 6. 技術スタック（日本版から変更なし）

| カテゴリ | 採用技術 |
|---|---|
| データベース | PostgreSQL 12+ |
| 空間拡張 | PostGIS 3.0+ |
| スクリプト言語 | Python 3.9+ |
| GISデスクトップ | QGIS 3.x |
| Pythonライブラリ（新規追加） | `census`, `cenpy`, `pygris` |
| Pythonライブラリ（既存） | `geopandas`, `pandas`, `numpy`, `matplotlib`, `pyproj`, `shapely` |

---

## 7. 注意点・リスク

| 項目 | 内容 |
|---|---|
| Census APIキー | 無償・即日発行。`api.census.gov/data/key_signup.html` から取得 |
| ACSデータの性質 | 推計値（Margin of Error付き）のため、分析コード内に注記が必要 |
| TIGER/Lineスキーマ | 国土数値情報と異なる部分があるため、スキーマ設計に調査が必要 |
| 座標系 | 米国はNAD83 / State Plane座標系が一般的。WGS84との変換処理を整備する |
| FIPS Code | 米国の地域コード体系。日本のJISコードに相当。州2桁＋郡3桁の計5桁がCounty識別子 |

---

## 8. 推奨着手順序（Claude Codeでの実装ステップ）

1. **環境構築**：PostGIS DB作成、スキーマ設計（`admin_us` / `census_us`）
2. **データ取得パイプライン**：Census API + TIGER/Line の自動取得スクリプト（`python/00_data_pipeline/`）
3. **基本SQLテンプレート**：逆ジオコーディング・距離計算（`sql/01_basic/`）
4. **分析SQLテンプレート**：商圏人口・デモグラフィックランキング（`sql/02_analysis/`）
5. **Pythonユーティリティ**：`gis_utils/` ライブラリ（FIPS Code・State Plane変換）
6. **可視化・アウトプット生成**：コロプレス図・散布図
7. **README整備**：英語で記述（海外クライアント向け）

---

*作成日：2026年4月*  
*参照元チャット：Claude.ai での Feasibility Study ディスカッション*
