---
title: アーキテクチャ
description: Hex NFC の Swift パッケージを構成するターゲットと、すべてのターゲットに共通する規約を説明します。
audience: developer
tags:
  - architecture
---

iOS 17 以降の iPhone 向け SwiftUI アプリである Hex NFC が、どのように構成されているかを大まかに紹介します。日々の作業で必要になる細部は、[ソースコード](https://github.com/hexpro-dev/hex-nfc-ios)を読んでください。

## モジュールグラフ

```text
HexNFCApp ─┬─> HexNFCDesign  ──> HexNFCShaders
           ├─> HexNFCStorage ──> HexNFCRecords
           ├─> HexNFCKit     ──> HexNFCRecords
           ├─> HexPromoKit   (vendored, product-less)
           └─> HexNFCTestKit ──> HexNFCKit, HexNFCRecords
HexNFCTagSim ──> HexNFCKit  (test-only)
```

### `HexNFCRecords`

値型とそのコーデックです。`NDEFRecord` 列挙型の 18 のケースが、アプリが読み書きできるすべてのレコードの種類を表します。その内訳は、テキスト、URI、アプリリンク、ソーシャル（22 のプラットフォーム）、検索、ファイル、メール、vCard、電話、SMS、FaceTime、地図、暗号資産、Bluetooth ハンドオーバー、Wi-Fi WPS、データ（MIME タイプと生のペイロード）、ショートカット、生データです。このターゲットには、パスポートのデータグループと Suica の利用履歴のモデルとデコーダーも含まれます。さらに `StationDirectory` もここにあり、`TransitReader` が駅名を付けるために使う、同梱の駅と路線のデータを読み込みます。

`NDEFCodec` は、`[NDEFRecord]`、ワイヤーレベルの `[NDEFPayload]`、生のメッセージバイト列の間を相互に変換します。`NDEFPayload` を CoreNFC に橋渡しするのは `HexNFCKit` だけです。URI プレフィックス表（NDEF の URI 識別コード `0x00` から `0x23` までの 36 個で、`0x00` はプレフィックスなしを意味します）も、最長プレフィックス一致による逆引きとあわせてここにあります。

### `HexNFCKit`

NFC の抽象化層です。`TagSession` はプロトコルで、本番のコードはこれを `CoreNFCSession`（`NFCTagReaderSession` のラッパー）に、ユニットテストは `SimulatedSession` に接続します。UI テストは `--useSimulatedNFC` を付けてアプリを起動し、`MockTagSession` に差し替えます。これは `HexNFCKit` にある代用品で、決まったレコードを返すだけでチップのモデルを持ちません。この起動引数のチェックは `#if DEBUG` で囲まれていないため、モックはリリースビルドにもコンパイルされます。`ConnectedTag` は、チップの機能を `TagCapability` オプションセットとして公開します。実物のタグをかざしたとき、セッションが識別できなかったタグには、NDEF の読み取り、NDEF の書き込み、生の送受信が割り当てられます。`permanentLock()` と Type 2 のパスワードコマンドは `ConnectedTag` の拡張に一度だけ書かれており、チップにその機能がない場合は、フレームを送る前に `TagError.capabilityUnsupported` をスローします。本番のタグである `CoreNFCConnectedTag` も、メモリの読み書きを同じ方法で制限しています。生の `transceive` には制限がありません。

`TagIdentifier` は CoreNFC のタグの種類ごとにプローブを選び、`ChipCatalog` はプローブが読み取った内容を、チップファミリー、機能、メモリレイアウトを持つ `ChipProfile` にデコードします。NTAG213、NTAG215、NTAG216、NTAG213 TT、NTAG 210µ、MIFARE Ultralight EV1 は `GET_VERSION` から識別します。NTAG210、NTAG212、NTAG213F、NTAG216F も `GET_VERSION` に応答しますが、メモリマップを実物のチップで確かめていないため、デコーダーはあえて識別しないままにしています。NTAG424 DNA は、ラップされた `GET_VERSION` APDU から識別します。このデコーダーはベンダーとハードウェア種別のバイトしか確認しないため、NTAG 4xx のハードウェア種別を報告する NXP のチップはすべて NTAG424 DNA として識別され、そのチップのプロファイルが割り当てられます。DESFire は、ネイティブの `GET_VERSION` フレームから識別します。iOS が NFC Forum の NDEF アプリケーション（`D2760000850101`。eMRTD の AID の後に宣言）経由で渡したタグは、まず通常の SELECT と READ BINARY のコマンドで読み取ります（`Type4NDEFProbe`）。PHD レコードで始まるメッセージは NFC ヘルスケア機器です。`PHDAssociation` がその関連付け要求を解析し、`HealthDeviceMaker` が OUI からメーカーを特定します。プロファイルには `.personalHealthDevice` だけが付くため、書き込み、消去、コンソールのコマンドはフレームを送る前に拒否されます。それ以外のタグには `GET_VERSION` を要求し、この経路で届いた NTAG424 DNA や DESFire を認識します（`identify(type4Version:)`）。残りのタグには汎用の `genericType4` プロファイル（NDEF の読み取り、NDEF の書き込み、生コマンド）が割り当てられます。MIFARE Ultralight C は `GET_VERSION` を拒否し、それによってタグが停止するため、セッションはポーリングをやり直し、ページ 0 と 28h の読み取りからチップを認識します。ISO 15693 のタグは、IC メーカーコードと Get System Information から判別します。NXP 製のチップは ICODE SLIX に、80 ブロックを報告した場合は SLIX2 になり、それ以外のメーカーのチップには汎用の ISO 15693 プロファイルが割り当てられます。パスポートは、eMRTD アプリケーションを選択することで認識します。FeliCa カードには汎用のプロファイルが割り当てられ、システムコード `0003` の場合は交通系カードの読み取りが加わります。`ChipCatalog` には EM Microelectronic V10、V11、V16 のプロファイルとデコーダー（`identify(emSignature:)`）もありますが、本番のセッションにこのデコーダーを呼び出す箇所はないため、実物のタグをかざしても、アプリは EM のチップを識別しません。デコーダーが照合するページ 0 のバイト（`E0 10`、`E0 11`、`E0 16`）は、EM のシミュレーターが独自に定めた値であり、EM の実チップから読み取った値ではありません。

「高度なコンソール」の組み込みコマンドは `CommandPresetCatalog` にあり、それぞれに対象のチップファミリーが指定されています。プリセットがあるのは Type 2 のチップ（EM のチップを含む）、NTAG424 DNA、ICODE SLIX で、DESFire、FeliCa、パスポート向けのものはありません。EM のプリセットは実チップで試験されていません。V10 の暗号モードのコマンドと改ざん検知の状態の読み取りにはシミュレーターが定めた値を使っており、EM の各パーソナライズ用のコマンド列が書き込む Capability Container のサイズバイトは、データシートではなく `ChipCatalog` のメモリレイアウトから取っています。コンソールはすべてのプリセットを一覧に表示し、読み込まれた内容をタグのファミリーを確かめずに実行します。そのため、EM のプリセットが EM 以外のチップのタグに送られるのを妨げるものはありません。

このターゲットには、保護の仕組みを持つファミリーごとの保護ドライバー、`DESFireNDEFDriver`（空の MIFARE DESFire EV1、EV2、EV3 に NDEF アプリケーションを作成・削除し、その設定がこのアプリによるものかどうかをカード自身の構造から確かめます）、FeliCa の `TransitReader`、読み取り専用のパスポートリーダーも含まれます。`EPassportReader` は、パスポートの `EF.CardAccess` が対応している構成を示していれば PACE を、そうでなければ BAC を実行します。示された PACE が失敗すると読み取りは失敗し、BAC で再試行することはありません。チップのセキュリティオブジェクト（`EF.SOD`）を読み取れた場合は、読み取った各データグループのハッシュを計算してそのオブジェクト内のハッシュ一覧と照合し、結果画面でデータに「改ざんなしとみられる」または「改ざんの疑いあり」と表示します。読み取れるセキュリティオブジェクトがない場合や、読み取ったデータグループがそこに 1 つも記載されていない場合は、画面に完全性の表示は何も出ません。リーダーはセキュリティオブジェクトの署名も証明書チェーンも検証しないため、これはパッシブ認証（Passive Authentication）ではありません。改変されたデータに合わせて書き換えられたセキュリティオブジェクトはこのチェックを通過し、アプリのどの処理によっても、パスポートが本物であることは確かめられません。

### `HexNFCStorage`

SwiftData スタック（`SwiftDataStack`）で、次の 3 つのモデルを扱います。
- `Preset` は、名前付きのタグイメージ（レコードの一覧と、任意で指定する機能要件）です。
- `HistoryEntry` はスキャンの記録で、タグや交通系カードの読み取りが成功するたびにスキャンフローが書き込みます。パスポートやヘルスケア機器の場合は書き込みません。まったく同じスキャンを繰り返したときは、行を追加せずに既存の行の時刻を更新します。ピン留めされていないエントリのうち、新しい順に 50 件を超えた分は挿入のたびに削除され、90 日より古いものは起動時に削除されます。
- `SavedCommandPreset` は HexNFCKit の `CommandPreset` を保存するための形式で、ユーザーが保存したコンソールのコマンドに使う想定です。スキーマには含まれていますが、アプリ内でこれを読み書きする箇所はまだなく、「高度なコンソール」には組み込みのプリセットだけが表示されます。

iCloud のプライベートデータベースへのミラーリングは、Hex NFC の「設定」にあるスイッチ（初期値はオフ）に連動する 1 つの構成フラグで切り替わります。このフラグは起動時にストアを開くときに読み取られるため、変更は次にアプリを起動したときに反映されます。その時点でミラーリングを有効にしてストアを開けなかった場合、アプリはミラーリングなしでストアを開き、「設定」には同期が実行されていないと表示されます。保護の秘密が SwiftData に入ることはありません。`KeychainProtectionCredentialStore`（プリセットをキーとする）と `KeychainTagCredentialStore`（タグの UID をキーとする）が、同期されない `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` の項目として、秘密をキーチェーンに保存します。

### `HexNFCShaders`

スキャン、書き込み、コンソールの特徴的な演出に使う Metal シェーダーと CoreHaptics パターンです。シェーダーは SPM の Metal ツールチェーンがコンパイルする `.metal` ソースファイルで、触覚パターンは `.ahap` 形式の JSON です。SwiftUI の `.hexHero(...)` モディファイアは、指定した演出の触覚パターンを再生します。それぞれの演出の視覚的な部分は別のモディファイア（`hexScanReveal`、`hexWriteBurst`、`hexConsolePulse`）が担い、画面が同じトリガーでそれを付加します。

### `HexNFCDesign`

デザイントークン（`HexTokens`）、モーションのプリセット、特徴的な `HexTransition`、コンポーネントの基本部品です。このトランジションは六角形のロゴを 3 つのスライスとして描くもので、`state` が `.hidden` から `.present` に変わると、スライスが時間差のスプリングアニメーションで現れます。ただし、アプリ内で使っている箇所はすべて `.present` を渡しているため、この時間差のアニメーションが再生されることはありません。コンポーネントの基本部品は `HexCard`、`HexButton`、`HexField`、`HexBadge`、`HexRecordRow`、`HexConsole` です。

### `HexNFCApp`

ライブラリとしてビルドされる、SwiftUI の画面とフローモデルです。エンタイトルメントと `Info.plist` を持つ Xcode のアプリシェル（`HexNFC.xcodeproj`）が `AppModel` を生成し、`RootView` を表示します。画面を動かすのは、フローごとの `@Observable` モデル（`ScanFlowModel`、`EditFlowModel` など）です。`RootView` は `HomeView` を囲む `NavigationStack` を 1 つ持ち、各フローをシートとして表示します。スキャンから編集、書き込みまでの流れはシートの連鎖（`ScanSheet` の次に `TagEditorSheet`、そこから `WriteSheet` を表示）になっているため、ステップの間にルートのスタックがポップされることはありません。画面には、レコードの種類によって多態的に振る舞う `RecordEditorSheet` も含まれます。

このターゲットは、独自の HTTP クライアントも 3 つ持っています。`CostsClient` は、ルートビューが表示されたときに、ユーザーの操作なしで、Hex NFC のホーム画面に表示する開発費の数値を取得します。`StationSubmissionClient` は、同梱のデータで名前を付けられない交通系の駅にユーザーが名前を送信したときだけ動作し、その名前を、駅の路線コード、駅コード、地域コード、カードのシステムコードとともに送信します。カードの IDm、残高、利用履歴は送信しません。`FeedbackClient` は、ユーザーがフィードバックのフォームで「送信」をタップしたときだけ動作し、入力されたメッセージ、任意の返信先、フォームに表示されるアプリのバージョン、iOS のバージョン、デバイスの機種、アプリの言語を `api.hex.pro` に送信します。タグから読み取ったものや履歴の内容は何も送信しません。

パスポートの鍵はカメラから取得することもできます。`MRZCameraView` がフレームをデバイス上の Vision のテキスト認識に渡し、`HexNFCRecords` の `MRZLineReader` が認識した行を鍵の候補に変換し、`MRZScanConsensus` が複数のフレームで多数決をとってから 1 つに確定します。フレームは保存しません。

### `HexPromoKit`

Hex NFC のホーム画面に表示するクロスプロモーションのバナーを支えるクライアントです。`PromoManager` は Hex Pro のプロモーション API から有効なプロモーションを取得し、そのメディアとともにディスクにキャッシュします。バナーの描画は `HexNFCApp` 自身が行います。このターゲットは Hex Pro 独自のプロモーション SDK からローカルの変更なしでコピーしたもので、ソースの横にある来歴ファイルに、固定したコミットと各ファイルのハッシュが記録されています。利用するのは `HexNFCApp` だけなので、パッケージはこのターゲットのプロダクトを宣言していません。

### `HexNFCTestKit`

セッションに依存しないテストプランと、実際の NFC ハードウェアとシミュレーターの両方を 1 つのコードパスで動かすランナーです。アプリにリンクされる実体のあるライブラリターゲットですが、これをインポートする `HexNFCApp` のファイルはすべて `#if DEBUG` の下でのみコンパイルされ、そこではアプリ内のハードウェアハーネスが実物のタグに対してプランを実行します。ヘッドレスの XCTest（`TestKitPlanTests`）は、チッププロファイルを持つすべてのシミュレーターに対して同じプランを実行します。シミュレーターと実チップのずれは、シミュレーターでは通るステップが実物のタグでは失敗する、という形で現れます。そのため、ずれを検出できるのは、誰かが実物のタグでハーネスを実行したときだけです。リリースビルドはこのターゲットをリンクしますが、そこに到達する画面はありません。

### `HexNFCTagSim`（テスト専用）

プロセス内で動くチップシミュレーターで、対象は NTAG 210µ、NTAG213/215/216、NTAG213 TT、NTAG424 DNA、MIFARE Ultralight C、MIFARE Ultralight EV1（48 バイトと 128 バイト）、MIFARE DESFire EV3、ICODE SLIX と SLIX2（28 ブロックまたは 80 ブロックで動く 1 つの ISO 15693 シミュレーター）、EM Microelectronic V10/V11/V16、Suica、電子パスポート（eMRTD）、NXP 以外の NFC Forum Type 4 タグと NFC ヘルスケア機器（`Type4NDEFSimulator`、`PHDCDeviceSimulator`）、認識されない Type 2 のフォールバックです。いずれも `ChipSimulator` に準拠するクラスで、その生の送受信の窓口は `func handle(command: Data) -> Data` です。シミュレーターは参照型なので、テストが引き起こす変更（カウンター、試行回数の上限、ロックバイト）は、それを作成したテストから見えます。テストターゲットは `SimulatedSession(chip:)` を通じてシミュレーターを注入します。シミュレートされたタグは、識別ではなくシミュレーターからチッププロファイルを受け取ります。そのため、テストではプロファイルを持つすべてのシミュレーターが識別済みとして読み取られ、EM のシミュレーターも例外ではありません。一方、実物のタグをかざしたときには、アプリは EM のチップを認識しません。EM Microelectronic のシミュレーターは、ページ 0 の識別子、各バリアントの改ざん検知の状態のページ、V10 の暗号モードの応答に、データシートの値ではなく独自に定めたバイト値を使っています。これらのチップのコマンドセット全体が公開されていないためです。また、`GET_VERSION` に 8 バイトのゼロで応答しますが、公開されている最も近い EM のチップのコマンドセットには、`GET_VERSION` がそもそもありません。EM のチップはハードウェアで一度も試験されていないため、EM のシミュレーターのテストが通っても、EM の実チップについての根拠にはなりません。

## 規約

- CoreNFC へのアクセスはすべて `HexNFCKit` の中にあります。ほかのターゲットは `CoreNFC` をインポートしません。
- ブランドカラーはトークン（`HexTokens.Color.primary`）で指定し、`HexTokens.swift` の外で 16 進数のリテラルを使うことはありません。
- ユーザーに表示する文字列は `Localizable.xcstrings` を、`Info.plist` の文字列（アプリ名とアクセス許可を求めるメッセージ）は `InfoPlist.xcstrings` を通します。
- NFC 層のエラー型である `TagError` は、`userMessage: LocalizedStringResource` と `diagnostics: String` の両方を持ち、不具合の報告にワイヤーレベルの詳細を含められるようにしています。
- サードパーティの Swift パッケージは `pointfreeco/swift-snapshot-testing` だけで、使うのはテストターゲットのみです。`HexPromoKit` は Hex Pro 自身のコードで、取得するのではなくリポジトリに取り込んでいます。アプリには IBM Plex Mono フォントも SIL OFL 1.1 のもとで同梱しています。
