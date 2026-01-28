--[[
ReaScript Name: Realtime Lyric Autofill per Note
Description  : 入力した歌詞を、アクティブMIDIテイクのノート数に合わせて
               1文字ずつリアルタイムで割り当てる
Author       : ChatGPT
Version      : 1.0
Usage        : MIDIエディタを開いた状態で実行
               - スクリプト開始時に歌詞を1行入力
               - 以降、ノートを置く／消すたびに自動で歌詞が振られる
Notes        :
  - 歌詞はMIDIテキストイベント(type=5: lyric)として挿入
  - 既存の歌詞イベント(type=5)は毎回削除してから再生成
  - 日本語を含むUTF-8文字列に対応（1文字=1コードポイント扱い）
]]

------------------------------------------------------------
-- UTF-8文字列を1文字ずつに分解するユーティリティ
------------------------------------------------------------
local function utf8_to_chars(str)
    local chars = {}
    local i = 1
    local len = #str
    while i <= len do
      local c = str:byte(i)
      local char_len = 1
      if not c then break end
      if c >= 0xF0 then
        char_len = 4
      elseif c >= 0xE0 then
        char_len = 3
      elseif c >= 0xC0 then
        char_len = 2
      else
        char_len = 1
      end
      table.insert(chars, str:sub(i, i + char_len - 1))
      i = i + char_len
    end
    return chars
  end
  
  ------------------------------------------------------------
  -- 日本語の仮名から母音を抽出する関数
  ------------------------------------------------------------
local function extract_vowel(text)
  if not text or text == "" then
    return ""
  end
  
  -- 最後の文字を取得（拗音・促音対応）
  local chars = utf8_to_chars(text)
  if #chars == 0 then
    return ""
  end
  
  local last_char = chars[#chars]
  
  -- 母音マッピングテーブル
  local vowel_map = {
    -- あ行
    ["あ"] = "あ", ["い"] = "い", ["う"] = "う", ["え"] = "え", ["お"] = "お",
    ["ア"] = "あ", ["イ"] = "い", ["ウ"] = "う", ["エ"] = "え", ["オ"] = "お",
    -- か行
    ["か"] = "あ", ["き"] = "い", ["く"] = "う", ["け"] = "え", ["こ"] = "お",
    ["カ"] = "あ", ["キ"] = "い", ["ク"] = "う", ["ケ"] = "え", ["コ"] = "お",
    -- さ行
    ["さ"] = "あ", ["し"] = "い", ["す"] = "う", ["せ"] = "え", ["そ"] = "お",
    ["サ"] = "あ", ["シ"] = "い", ["ス"] = "う", ["セ"] = "え", ["ソ"] = "お",
    -- た行
    ["た"] = "あ", ["ち"] = "い", ["つ"] = "う", ["て"] = "え", ["と"] = "お",
    ["タ"] = "あ", ["チ"] = "い", ["ツ"] = "う", ["テ"] = "え", ["ト"] = "お",
    -- な行
    ["な"] = "あ", ["に"] = "い", ["ぬ"] = "う", ["ね"] = "え", ["の"] = "お",
    ["ナ"] = "あ", ["ニ"] = "い", ["ヌ"] = "う", ["ネ"] = "え", ["ノ"] = "お",
    -- は行
    ["は"] = "あ", ["ひ"] = "い", ["ふ"] = "う", ["へ"] = "え", ["ほ"] = "お",
    ["ハ"] = "あ", ["ヒ"] = "い", ["フ"] = "う", ["ヘ"] = "え", ["ホ"] = "お",
    -- ま行
    ["ま"] = "あ", ["み"] = "い", ["む"] = "う", ["め"] = "え", ["も"] = "お",
    ["マ"] = "あ", ["ミ"] = "い", ["ム"] = "う", ["メ"] = "え", ["モ"] = "お",
    -- や行
    ["や"] = "あ", ["ゆ"] = "う", ["よ"] = "お",
    ["ヤ"] = "あ", ["ユ"] = "う", ["ヨ"] = "お",
    -- ら行
    ["ら"] = "あ", ["り"] = "い", ["る"] = "う", ["れ"] = "え", ["ろ"] = "お",
    ["ラ"] = "あ", ["リ"] = "い", ["ル"] = "う", ["レ"] = "え", ["ロ"] = "お",
    -- わ行
    ["わ"] = "あ", ["を"] = "お",
    ["ワ"] = "あ", ["ヲ"] = "お",
    -- 濁音: が行
    ["が"] = "あ", ["ぎ"] = "い", ["ぐ"] = "う", ["げ"] = "え", ["ご"] = "お",
    ["ガ"] = "あ", ["ギ"] = "い", ["グ"] = "う", ["ゲ"] = "え", ["ゴ"] = "お",
    -- 濁音: ざ行
    ["ざ"] = "あ", ["じ"] = "い", ["ず"] = "う", ["ぜ"] = "え", ["ぞ"] = "お",
    ["ザ"] = "あ", ["ジ"] = "い", ["ズ"] = "う", ["ゼ"] = "え", ["ゾ"] = "お",
    -- 濁音: だ行
    ["だ"] = "あ", ["ぢ"] = "い", ["づ"] = "う", ["で"] = "え", ["ど"] = "お",
    ["ダ"] = "あ", ["ヂ"] = "い", ["ヅ"] = "う", ["デ"] = "え", ["ド"] = "お",
    -- 濁音: ば行
    ["ば"] = "あ", ["び"] = "い", ["ぶ"] = "う", ["べ"] = "え", ["ぼ"] = "お",
    ["バ"] = "あ", ["ビ"] = "い", ["ブ"] = "う", ["ベ"] = "え", ["ボ"] = "お",
    -- 半濁音: ぱ行
    ["ぱ"] = "あ", ["ぴ"] = "い", ["ぷ"] = "う", ["ぺ"] = "え", ["ぽ"] = "お",
    ["パ"] = "あ", ["ピ"] = "い", ["プ"] = "う", ["ペ"] = "え", ["ポ"] = "お",
  }
  
  return vowel_map[last_char] or ""
end

  ------------------------------------------------------------
  -- 歌詞を現在のテイクのノートに流し込む処理
  ------------------------------------------------------------
local function apply_lyrics_to_notes(take, lyric_chars)
    if not take then return end
    local _, note_count, _, text_count = reaper.MIDI_CountEvts(take)
  
    -- 既存の lyric(text type=5) を削除
    -- 後ろから消さないとインデックスがずれるので逆順
    for i = text_count - 1, 0, -1 do
      local retval, selected, muted, ppqpos, typ, msg = reaper.MIDI_GetTextSysexEvt(
        take, i, true, true, 0, 0, ""
      )
      if retval and typ == 5 then
        reaper.MIDI_DeleteTextSysexEvt(take, i)
      end
    end
  
    local max_notes = math.min(note_count, #lyric_chars)
  
    -- 各ノート頭に歌詞1文字を挿入
    for i = 0, max_notes - 1 do
      local ok, sel, mut, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      if ok then
        local ch = lyric_chars[i + 1] or ""
        reaper.MIDI_InsertTextSysexEvt(
          take,
          false,  -- selected
          false,  -- muted
          startppq,
          5,      -- 5 = lyric
          ch
        )
      end
    end
  end
  
------------------------------------------------------------
-- 歌詞ファイル監視 + MIDI 反映（非 GUI）
------------------------------------------------------------

-- 歌詞は外部テキストファイルから読み込みます。
-- → OS のテキストエディタで日本語入力・貼り付けが自由にできます。

local lyric_text = ""              -- 現在ファイルから読み込んだ歌詞（複数行）
local lyric_chars = nil            -- ノートに割り当てる用の文字配列（改行除去済み）
local last_lyric_text = nil        -- 前フレームの歌詞テキスト
local last_note_count = -1         -- 前フレームのノート数（互換用）
local gui_initialized = false      -- 状態表示用のシンプルなウィンドウ
local last_mouse_cap = 0           -- クリック検出用（gfxウィンドウ内）
local last_js_mouse_state = 0      -- JS_Mouse_GetState の前フレーム値
local last_note_signature = nil    -- ノート配列のシグネチャ（位置・長さ・ピッチを含む）
local last_note_change_time = 0    -- 最後にノート配列が変化した時刻
local upcoming_preview = ""        -- 次に挿入される予定の歌詞プレビュー（最大10ノート分）

-- 歌詞用 Undo / Redo 用の履歴
local lyric_history = {}           -- 各要素は { text = "全文" }
local lyric_history_index = 0      -- 現在指している履歴のインデックス（0 のとき履歴なし）
local lyric_history_max = 100      -- 最大保存数（必要なら調整可能）

-- 現在のプロジェクト名から歌詞ファイル名を決定
-- 例: プロジェクトファイルが "MySong.rpp" の場合 → "MySong_lyrics.txt"
--     未保存プロジェクトなどで名前が取得できない場合 → 既存の固定名を使用
local project_dir = reaper.GetProjectPath("")

local function get_project_base_name()
  -- アクティブプロジェクトのファイルパスを取得
  local _, proj_fn = reaper.EnumProjects(-1, "")
  if not proj_fn or proj_fn == "" then
    return nil
  end

  -- パス部分を除去（最後の区切り以降を取得）
  local name = proj_fn:match("([^/\\]+)$") or proj_fn
  -- 拡張子を除去（例: ".rpp"）
  name = name:gsub("%.%w+$", "")

  if name == "" then
    return nil
  end
  return name
end

local project_base_name = get_project_base_name()

local lyrics_file_path
if project_base_name then
  lyrics_file_path = project_dir .. "/" .. project_base_name .. "_lyrics.txt"
else
  -- フォールバック: 従来どおりの固定ファイル名
  lyrics_file_path = project_dir .. "/ReaperLyricTools_lyrics.txt"
end

-- 歌詞ファイル読み込み
local function read_lyrics_file()
  local f = io.open(lyrics_file_path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a") or ""
  f:close()
  return content
end

-- 歌詞ファイルを（なければ）生成
local function ensure_lyrics_file()
  local f = io.open(lyrics_file_path, "r")
  if f then
    f:close()
    return false -- 既に存在
  end
  f = io.open(lyrics_file_path, "w")
  if f then
    f:write("") -- 空ファイルを作成
    f:close()
    return true -- 新規作成した
  end
  return false
end

-- 履歴に現在の歌詞状態を追加（GUI 操作の直前に呼ぶ）
local function push_lyric_history()
  -- 現在のテキストを基準にする（ファイル・配列と同期している前提）
  local current_text = lyric_text or ""

  -- 直前と同じならスキップ（ノイズ防止）
  if lyric_history_index > 0 and lyric_history[lyric_history_index]
     and lyric_history[lyric_history_index].text == current_text then
    return
  end

  -- Redo 可能な履歴は破棄（通常の Undo 系挙動）
  for i = lyric_history_index + 1, #lyric_history do
    lyric_history[i] = nil
  end

  -- 新しい履歴を末尾に追加
  table.insert(lyric_history, { text = current_text })

  -- 最大数を超えた場合は先頭を落とす
  if #lyric_history > lyric_history_max then
    table.remove(lyric_history, 1)
  end

  lyric_history_index = #lyric_history
end

-- 与えられたテキストを「正」として、TXT と内部状態と MIDI をまとめて反映
local function apply_lyrics_text_to_all(new_text)
  lyric_text = new_text or ""
  update_lyric_chars()
  last_lyric_text = lyric_text

  -- TXT ファイルに書き戻し
  local f = io.open(lyrics_file_path, "w")
  if f then
    f:write(lyric_text)
    f:close()
  end

  -- アクティブテイクにも即反映（ノート数ぶんだけ先頭から割り当て）
  local editor = reaper.MIDIEditor_GetActive()
  if not editor then return end

  local take = reaper.MIDIEditor_GetTake(editor)
  if not take then return end

  local _, note_count, _, text_count = reaper.MIDI_CountEvts(take)
  if note_count <= 0 then return end

  reaper.MIDI_DisableSort(take)
  -- 既存 lyric イベント削除
  for i = text_count - 1, 0, -1 do
    local retval, _, _, _, typ = reaper.MIDI_GetTextSysexEvt(
      take, i, true, true, 0, 0, ""
    )
    if retval and typ == 5 then
      reaper.MIDI_DeleteTextSysexEvt(take, i)
    end
  end

  -- 先頭から順に再割り当て
  local max_notes = math.min(note_count, lyric_chars and #lyric_chars or 0)
  for i = 0, max_notes - 1 do
    local ok_note, _, _, startppq = reaper.MIDI_GetNote(take, i)
    if ok_note then
      local ch = lyric_chars[i + 1] or ""
      reaper.MIDI_InsertTextSysexEvt(
        take,
        false,
        false,
        startppq,
        5,
        ch
      )
    end
  end
  reaper.MIDI_Sort(take)
end

-- 入力テキストから歌詞ユニット配列（拗音・促音マージ済み）を作成
local function build_lyric_units_from_text(text)
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  -- ノート数に対応させるため、改行は歌詞割り当てからは除外（見た目用のみ）
  normalized = normalized:gsub("\n", "")
  local chars = utf8_to_chars(normalized)

  -- 日本語の拗音・促音など（小さい仮名）を直前の文字とまとめて1音節として扱う
  -- 例: 「き」「ょ」 -> 「きょ」
  local small_kana = {
    ["ぁ"]=true, ["ぃ"]=true, ["ぅ"]=true, ["ぇ"]=true, ["ぉ"]=true,
    ["ゃ"]=true, ["ゅ"]=true, ["ょ"]=true,
    ["ゎ"]=true, ["っ"]=true,
    ["ァ"]=true, ["ィ"]=true, ["ゥ"]=true, ["ェ"]=true, ["ォ"]=true,
    ["ャ"]=true, ["ュ"]=true, ["ョ"]=true, ["ヮ"]=true, ["ッ"]=true
  }

  local units = {}
  for i = 1, #chars do
    local ch = chars[i]
    if small_kana[ch] and #units > 0 then
      -- 直前の音節に結合
      units[#units] = units[#units] .. ch
    else
      table.insert(units, ch)
    end
  end

  return units
end

-- 歌詞テキストが変わったときに文字配列を更新
function update_lyric_chars()
  lyric_chars = build_lyric_units_from_text(lyric_text)
end

------------------------------------------------------------
-- メインループ（テキストファイル監視 + MIDI反映）
------------------------------------------------------------

local last_check_time = 0
local check_interval = 0.2  -- 歌詞ファイル監視の更新間隔（秒）
local note_apply_delay = 0.6 -- 「ノート編集が落ち着いてから」歌詞を反映する待ち時間（秒）
local has_js_mouse = reaper.APIExists and reaper.APIExists("JS_Mouse_GetState") or false

local function main_loop()
  -- シンプルな常時表示ウィンドウ（gfx）
  if not gui_initialized then
    gfx.init("ReaperLyricTools", 480, 150, 0)
    gfx.dock(-1) -- ドッキング状態を記憶・復元
    gfx.setfont(1, "Arial", 15)
    gui_initialized = true
  end

  -- ウィンドウを閉じた / Esc でスクリプト終了
  local ch = gfx.getchar()
  if ch == -1 or ch == 27 then
    return
  end

  local now = reaper.time_precise()

  -- 一定間隔ごとに歌詞ファイルチェックのみ行う（軽い処理）
  if now - last_check_time >= check_interval then
    last_check_time = now
    local file_text = read_lyrics_file()

    if file_text ~= lyric_text then
      lyric_text = file_text
      update_lyric_chars()
      last_lyric_text = lyric_text
      -- 歌詞が変わったので、ノート配列が安定したタイミングで再割り当てをトリガする
      last_note_signature = nil
      last_note_change_time = 0
    end
  end

  -- MIDI処理: ノート数だけでなく、位置・長さ・ピッチなども含めて
  -- 「ノート配列が変化してから一定時間編集が止まったら」一度だけ歌詞を反映する。
  -- さらに JS_ReaScriptAPI があれば、マウス左ボタン押下中（ドラッグ中）は絶対に反映しない。
  local editor = reaper.MIDIEditor_GetActive()
  if editor and lyric_chars and #lyric_chars > 0 then
    local take = reaper.MIDIEditor_GetTake(editor)
    if take then
      local _, note_count = reaper.MIDI_CountEvts(take)
      if note_count > 0 then
        -- 現在のノート配列が「編集中かどうか」のフラグ
        local is_editing = false

        -- JS_ReaScriptAPI があれば、まずマウス左ボタンの状態を確認
        local mouse_down = false
        if has_js_mouse then
          local state = reaper.JS_Mouse_GetState(1) or 0 -- 1 = 左ボタン
          last_js_mouse_state = state
          mouse_down = (state & 1) == 1
        end

        if mouse_down then
          -- ドラッグ中はノートシグネチャも idle タイマーも更新せず、ひたすら「編集中」とみなす
          _G.__reaper_lyrictools_is_editing = true
        else

        -- ノート配列の簡易シグネチャを計算（位置・長さ・ピッチを含める）
        local sig = 0
        for i = 0, note_count - 1 do
          local ok, _, _, startppq, endppq, _, pitch, _ = reaper.MIDI_GetNote(take, i)
          if ok then
            -- シンプルな数値ハッシュ（ビット演算を使わず加算のみ）
            sig = (sig + startppq + endppq + pitch * 131) % 2147483647
          end
        end

          if last_note_signature == nil or sig ~= last_note_signature then
            -- ノート配列が変わった瞬間: シグネチャと時刻だけ記録
            last_note_signature = sig
            last_note_change_time = now
            is_editing = true
          else
            -- ノート配列が変わっていない状態が note_apply_delay 秒続いたら歌詞を反映
            local idle_time = (last_note_change_time > 0) and (now - last_note_change_time) or 0

            if last_note_change_time > 0 and idle_time >= note_apply_delay then
              reaper.MIDI_DisableSort(take)
              apply_lyrics_to_notes(take, lyric_chars)
              reaper.MIDI_Sort(take)
              -- 反映後はタイマーをリセット（次にノート配列が変わるまで動かない）
              last_note_change_time = 0
              is_editing = false
            else
              -- まだ待機時間内なので「編集中」とみなす
              if idle_time > 0 then
                is_editing = true
              end
            end
          end
        end

        -- is_editing フラグをウィンドウ描画で使うために保存
        _G.__reaper_lyrictools_is_editing = is_editing

        -- 次に挿入される予定の歌詞（10ノート分）を更新
        local start_idx = note_count + 1
        local preview_units = {}
        local max_idx = math.min(start_idx + 9, #lyric_chars)
        for i = start_idx, max_idx do
          table.insert(preview_units, lyric_chars[i])
        end
        if #preview_units == 0 then
          upcoming_preview = "(これ以上の歌詞はありません)"
        else
          upcoming_preview = table.concat(preview_units, " | ")
        end
      end
    end
  end

  -- エディタやノートがない場合のプレビュー（歌詞全体の先頭から）
  if (not editor or not lyric_chars or #lyric_chars == 0) then
    if not lyric_chars or #lyric_chars == 0 then
      upcoming_preview = "(歌詞が読み込まれていません)"
    else
      local preview_units = {}
      local max_idx = math.min(10, #lyric_chars)
      for i = 1, max_idx do
        table.insert(preview_units, lyric_chars[i])
      end
      upcoming_preview = table.concat(preview_units, " | ")
    end
  end

  -- ------------------------------
  -- ウィンドウ描画（超シンプルレイアウト）
  -- ------------------------------
  gfx.set(0.1, 0.1, 0.1, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  gfx.set(1, 1, 1, 1)
  gfx.x, gfx.y = 10, 10
  gfx.drawstr("歌詞ファイル: ")
  gfx.set(0.7, 0.9, 0.7, 1)
  gfx.drawstr(lyrics_file_path)

  gfx.y = gfx.y + 18
  gfx.x = 10
  gfx.set(0.8, 0.8, 0.8, 1)
  gfx.drawstr("このファイルをテキストエディタで開いて編集してください（日本語・複数行OK）。")

  -- 状態表示
  local is_editing = _G.__reaper_lyrictools_is_editing
  gfx.y = gfx.y + 18
  gfx.x = 10
  if is_editing then
    gfx.set(0.9, 0.6, 0.4, 1)
    gfx.drawstr("ノート編集中: 歌詞反映を待機中…")
  else
    gfx.set(0.4, 0.9, 0.4, 1)
    gfx.drawstr("待機中: 歌詞は最新の状態です。")
  end

  -- 次に入る歌詞プレビュー（最大10ノート分）
  gfx.y = gfx.y + 16
  gfx.x = 10
  gfx.set(0.8, 0.8, 0.8, 1)
  gfx.drawstr("次に挿入される歌詞 (最大10ノート): ")
  gfx.y = gfx.y + 16
  gfx.x = 10
  gfx.set(1, 1, 1, 1)
  gfx.drawstr(upcoming_preview or "")

  -- TXTファイル作成ボタン（左下）
  local btn_w, btn_h = 140, 22
  local btn_x = 10
  local btn_y = gfx.h - btn_h - 10

  gfx.set(0.3, 0.3, 0.3, 1)
  gfx.rect(btn_x, btn_y, btn_w, btn_h, 1)
  gfx.set(1, 1, 1, 1)
  gfx.x = btn_x + 10
  gfx.y = btn_y + 4
  gfx.drawstr("フォルダを開く")

  -- 「挿入」ボタン（TXTボタンの右隣）
  local ins_btn_w, ins_btn_h = 110, 22
  local ins_btn_x = btn_x + btn_w + 10
  local ins_btn_y = btn_y

  gfx.set(0.3, 0.3, 0.3, 1)
  gfx.rect(ins_btn_x, ins_btn_y, ins_btn_w, ins_btn_h, 1)
  gfx.set(1, 1, 1, 1)
  gfx.x = ins_btn_x + 10
  gfx.y = ins_btn_y + 4
  gfx.drawstr("挿入 (1行)")

  -- 「削除」ボタン（挿入ボタンの右隣）
  local del_btn_w, del_btn_h = 110, 22
  local del_btn_x = ins_btn_x + ins_btn_w + 10
  local del_btn_y = btn_y

  gfx.set(0.3, 0.3, 0.3, 1)
  gfx.rect(del_btn_x, del_btn_y, del_btn_w, del_btn_h, 1)
  gfx.set(1, 1, 1, 1)
  gfx.x = del_btn_x + 10
  gfx.y = del_btn_y + 4
  gfx.drawstr("削除 (選択)")

  -- 「変更」ボタン（削除ボタンの右隣）
  local edit_btn_w, edit_btn_h = 110, 22
  local edit_btn_x = del_btn_x + del_btn_w + 10
  local edit_btn_y = btn_y

  gfx.set(0.3, 0.3, 0.3, 1)
  gfx.rect(edit_btn_x, edit_btn_y, edit_btn_w, edit_btn_h, 1)
  gfx.set(1, 1, 1, 1)
  gfx.x = edit_btn_x + 10
  gfx.y = edit_btn_y + 4
  gfx.drawstr("変更 (選択)")

  -- 「挿入（母音）」ボタン（変更ボタンの右隣）
  local vowel_btn_w, vowel_btn_h = 120, 22
  local vowel_btn_x = edit_btn_x + edit_btn_w + 10
  local vowel_btn_y = btn_y

  gfx.set(0.3, 0.3, 0.3, 1)
  gfx.rect(vowel_btn_x, vowel_btn_y, vowel_btn_w, vowel_btn_h, 1)
  gfx.set(1, 1, 1, 1)
  gfx.x = vowel_btn_x + 6
  gfx.y = vowel_btn_y + 4
  gfx.drawstr("挿入（母音）")

  -- 「Undo（歌詞）」ボタン（母音ボタンの右隣）
  local undo_btn_w, undo_btn_h = 110, 22
  local undo_btn_x = vowel_btn_x + vowel_btn_w + 10
  local undo_btn_y = btn_y

  gfx.set(0.3, 0.3, 0.3, 1)
  gfx.rect(undo_btn_x, undo_btn_y, undo_btn_w, undo_btn_h, 1)
  gfx.set(1, 1, 1, 1)
  gfx.x = undo_btn_x + 10
  gfx.y = undo_btn_y + 4
  gfx.drawstr("Undo (歌詞)")

  -- 「Redo（歌詞）」ボタン（Undo ボタンの右隣）
  local redo_btn_w, redo_btn_h = 110, 22
  local redo_btn_x = undo_btn_x + undo_btn_w + 10
  local redo_btn_y = btn_y

  gfx.set(0.3, 0.3, 0.3, 1)
  gfx.rect(redo_btn_x, redo_btn_y, redo_btn_w, redo_btn_h, 1)
  gfx.set(1, 1, 1, 1)
  gfx.x = redo_btn_x + 10
  gfx.y = redo_btn_y + 4
  gfx.drawstr("Redo (歌詞)")

  gfx.update()

  -- ボタンクリック処理（左クリックの立ち上がりを検出）
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local mcap = gfx.mouse_cap
  if (last_mouse_cap & 1) == 0 and (mcap & 1) == 1 then
    if mx >= btn_x and mx <= (btn_x + btn_w)
       and my >= btn_y and my <= (btn_y + btn_h) then
      -- プロジェクトフォルダを開く
      -- SWS の CF_ShellExecute があればそれを使う（既定のファイラで開く）
      if reaper.APIExists and reaper.APIExists("CF_ShellExecute") then
        reaper.CF_ShellExecute(project_dir)
      else
        -- SWS が無い場合はパスだけ表示
        reaper.ShowMessageBox(
          "プロジェクトフォルダのパス:\n\n" ..
          project_dir ..
          "\n\nこのパスを Finder / エクスプローラ等で開いてください。",
          "ReaperLyricTools - フォルダを開く",
          0
        )
      end
    elseif mx >= ins_btn_x and mx <= (ins_btn_x + ins_btn_w)
       and my >= ins_btn_y and my <= (ins_btn_y + ins_btn_h) then
      -- 挿入ボタン: 1行入力して、テキストファイルに挿入のみ行う
      -- 歌詞ユニット配列が未構築なら構築
      if not lyric_chars or #lyric_chars == 0 then
        lyric_text = read_lyrics_file()
        update_lyric_chars()
        last_lyric_text = lyric_text
      end

      -- アクティブテイクから現在のノート情報を取得（デフォルト値決定のため）
      local editor = reaper.MIDIEditor_GetActive()
      local note_count = 0
      local last_selected_note_index = nil
      local selected_note_lyric = nil
      if editor then
        local take = reaper.MIDIEditor_GetTake(editor)
        if take then
          local _, nc, _, text_count = reaper.MIDI_CountEvts(take)
          note_count = nc or 0
          -- 選択されているノートのうち、インデックスが最大のものを探す
          for i = 0, note_count - 1 do
            local ok, sel = reaper.MIDI_GetNote(take, i)
            if ok and sel then
              last_selected_note_index = i
              -- 選択されたノートの位置を取得
              local ok_note, _, _, startppq = reaper.MIDI_GetNote(take, i)
              if ok_note then
                -- その位置にある歌詞イベント（type=5）を探す
                for j = 0, text_count - 1 do
                  local retval, _, _, ppqpos, typ, msg = reaper.MIDI_GetTextSysexEvt(
                    take, j, true, true, 0, 0, ""
                  )
                  if retval and typ == 5 and math.abs(ppqpos - startppq) < 10 then
                    -- 同じ位置（±10 ticks以内）の歌詞を見つけた
                    selected_note_lyric = msg
                    break
                  end
                end
              end
            end
          end
        end
      end

      -- デフォルト値: 選択されたノートの歌詞の母音、なければ次に挿入される予定の歌詞の最初のユニット
      local default_value = ""
      if selected_note_lyric and selected_note_lyric ~= "" then
        -- 選択されたノートの歌詞から母音を抽出
        default_value = extract_vowel(selected_note_lyric)
      elseif lyric_chars and #lyric_chars > 0 then
        local base_pos
        if last_selected_note_index ~= nil then
          base_pos = last_selected_note_index + 1
        else
          base_pos = note_count
        end
        local next_index = base_pos + 1
        if next_index <= #lyric_chars then
          default_value = lyric_chars[next_index] or ""
        end
      end

      -- 履歴に現在の状態を保存（このあと変更される）
      push_lyric_history()

      local ok, ret = reaper.GetUserInputs(
        "次に挿入される歌詞を追加",
        1,
        "挿入する文字（1行・数文字を推奨）:",
        default_value
      )
      if ok and ret ~= "" then

        -- 挿入テキストをユニット配列に変換
        local insert_units = build_lyric_units_from_text(ret)

        -- 既存ユニットに対して、挿入位置を決定
        local new_units = {}
        local total_units = (#lyric_chars)
        -- 挿入位置:
        -- - ノートが選択されていれば「最後に選択されているノートの次」
        -- - 何も選択されていなければ「既存ノートの末尾の次」
        local base_pos
        if last_selected_note_index ~= nil then
          base_pos = last_selected_note_index + 1
        else
          base_pos = note_count
        end
        local insert_pos = math.min(math.max(base_pos, 0), total_units)

        for i = 1, insert_pos do
          table.insert(new_units, lyric_chars[i])
        end
        for i = 1, #insert_units do
          table.insert(new_units, insert_units[i])
        end
        for i = insert_pos + 1, total_units do
          table.insert(new_units, lyric_chars[i])
        end

        lyric_chars = new_units

        -- ユニット配列からテキストを再構成して一括反映
        local new_text = table.concat(lyric_chars, "")
        apply_lyrics_text_to_all(new_text)
      end
    elseif mx >= del_btn_x and mx <= (del_btn_x + del_btn_w)
       and my >= del_btn_y and my <= (del_btn_y + del_btn_h) then
      -- 削除ボタン: 選択されたノートの歌詞を削除
      local editor = reaper.MIDIEditor_GetActive()
      if not editor then
        reaper.ShowMessageBox("MIDIエディタが開かれていません。", "ReaperLyricTools - エラー", 0)
      else
        local take = reaper.MIDIEditor_GetTake(editor)
        if not take then
          reaper.ShowMessageBox("アクティブなMIDIテイクがありません。", "ReaperLyricTools - エラー", 0)
        else
          -- 選択されたノートのインデックスを取得
          local _, note_count, _, text_count = reaper.MIDI_CountEvts(take)
          local selected_note_indices = {}
          for i = 0, note_count - 1 do
            local ok_note, sel = reaper.MIDI_GetNote(take, i)
            if ok_note and sel then
              selected_note_indices[i + 1] = true  -- 1-based で「このノートは選択されている」を記録
            end
          end

          local num_selected = 0
          for _ in pairs(selected_note_indices) do num_selected = num_selected + 1 end

          if num_selected == 0 then
            reaper.ShowMessageBox("ノートが選択されていません。", "ReaperLyricTools - エラー", 0)
          else
            -- 履歴に現在の状態を保存
            push_lyric_history()

            -- 歌詞ユニット配列が未構築なら構築
            if not lyric_chars or #lyric_chars == 0 then
              lyric_text = read_lyrics_file()
              update_lyric_chars()
              last_lyric_text = lyric_text
            end

            -- 選択されていないノートに対応する歌詞だけ残す（選択されたノートの歌詞を削除）
            local new_units = {}
            for i = 1, #lyric_chars do
              if not selected_note_indices[i] then
                table.insert(new_units, lyric_chars[i])
              end
            end
            lyric_chars = new_units

            local new_text = table.concat(lyric_chars, "")
            apply_lyrics_text_to_all(new_text)
          end
        end
      end
    elseif mx >= edit_btn_x and mx <= (edit_btn_x + edit_btn_w)
       and my >= edit_btn_y and my <= (edit_btn_y + edit_btn_h) then
      -- 変更ボタン: 選択されたノートの歌詞を編集
      local editor = reaper.MIDIEditor_GetActive()
      if not editor then
        reaper.ShowMessageBox("MIDIエディタが開かれていません。", "ReaperLyricTools - エラー", 0)
      else
        local take = reaper.MIDIEditor_GetTake(editor)
        if not take then
          reaper.ShowMessageBox("アクティブなMIDIテイクがありません。", "ReaperLyricTools - エラー", 0)
        else
          -- 選択されたノートを取得
          local _, note_count, _, text_count = reaper.MIDI_CountEvts(take)
          local selected_notes = {}
          local selected_note_indices = {}
          
          for i = 0, note_count - 1 do
            local ok, sel = reaper.MIDI_GetNote(take, i)
            if ok and sel then
              table.insert(selected_note_indices, i)
              local ok_note, _, _, startppq = reaper.MIDI_GetNote(take, i)
              if ok_note then
                -- その位置にある歌詞イベント（type=5）を探す
                local lyric_text_for_note = ""
                for j = 0, text_count - 1 do
                  local retval, _, _, ppqpos, typ, msg = reaper.MIDI_GetTextSysexEvt(
                    take, j, true, true, 0, 0, ""
                  )
                  if retval and typ == 5 and math.abs(ppqpos - startppq) < 10 then
                    lyric_text_for_note = msg
                    break
                  end
                end
                table.insert(selected_notes, {
                  index = i,
                  startppq = startppq,
                  lyric = lyric_text_for_note
                })
              end
            end
          end
          
          if #selected_notes == 0 then
            reaper.ShowMessageBox("ノートが選択されていません。", "ReaperLyricTools - エラー", 0)
          else
            -- 選択されたノートの歌詞を結合（デフォルト値として使用）
            local default_lyrics = {}
            for i = 1, #selected_notes do
              table.insert(default_lyrics, selected_notes[i].lyric or "")
            end
            local default_text = table.concat(default_lyrics, "")
            
            -- ダイアログで編集
            local ok, ret = reaper.GetUserInputs(
              "選択ノートの歌詞を変更 (" .. #selected_notes .. "個のノート)",
              1,
              "歌詞（" .. #selected_notes .. "文字推奨、多い場合は切り捨て、少ない場合は残りはそのまま）:",
              default_text
            )
            
            if ok then
              -- 履歴に現在の状態を保存
              push_lyric_history()
              -- 歌詞ユニット配列が未構築なら構築
              if not lyric_chars or #lyric_chars == 0 then
                lyric_text = read_lyrics_file()
                update_lyric_chars()
                last_lyric_text = lyric_text
              end
              
              -- 入力された文字列をユニット配列に変換
              local edit_units = build_lyric_units_from_text(ret)
              local edit_count = math.min(#edit_units, #selected_notes)
              
              -- 選択されたノートのインデックスに対応する歌詞ユニット配列の位置を更新
              local new_units = {}
              for i = 1, #lyric_chars do
                new_units[i] = lyric_chars[i]
              end
              
              -- 選択されたノートの位置に対応する歌詞を更新
              for i = 1, edit_count do
                local note_index = selected_notes[i].index
                if note_index + 1 <= #new_units then
                  new_units[note_index + 1] = edit_units[i]
                end
              end
              
              lyric_chars = new_units
              
              -- ユニット配列からテキストを再構成して一括反映
              local new_text = table.concat(lyric_chars, "")
              apply_lyrics_text_to_all(new_text)
            end
          end
        end
      end
    elseif mx >= vowel_btn_x and mx <= (vowel_btn_x + vowel_btn_w)
       and my >= vowel_btn_y and my <= (vowel_btn_y + vowel_btn_h) then
      -- 挿入（母音）ボタン: 選択されたノートの歌詞から母音を抽出して自動挿入（確認なし）
      -- 歌詞ユニット配列が未構築なら構築
      if not lyric_chars or #lyric_chars == 0 then
        lyric_text = read_lyrics_file()
        update_lyric_chars()
        last_lyric_text = lyric_text
      end

      local editor = reaper.MIDIEditor_GetActive()
      if not editor then
        reaper.ShowMessageBox("MIDIエディタが開かれていません。", "ReaperLyricTools - エラー", 0)
      else
        local take = reaper.MIDIEditor_GetTake(editor)
        if not take then
          reaper.ShowMessageBox("アクティブなMIDIテイクがありません。", "ReaperLyricTools - エラー", 0)
        else
          -- 選択されたノートを取得
          local _, note_count, _, text_count = reaper.MIDI_CountEvts(take)
          local last_selected_note_index = nil
          local selected_note_lyric = nil
          
          for i = 0, note_count - 1 do
            local ok, sel = reaper.MIDI_GetNote(take, i)
            if ok and sel then
              last_selected_note_index = i
              -- 選択されたノートの位置を取得
              local ok_note, _, _, startppq = reaper.MIDI_GetNote(take, i)
              if ok_note then
                -- その位置にある歌詞イベント（type=5）を探す
                for j = 0, text_count - 1 do
                  local retval, _, _, ppqpos, typ, msg = reaper.MIDI_GetTextSysexEvt(
                    take, j, true, true, 0, 0, ""
                  )
                  if retval and typ == 5 and math.abs(ppqpos - startppq) < 10 then
                    selected_note_lyric = msg
                    break
                  end
                end
              end
            end
          end
          
          if last_selected_note_index == nil then
            reaper.ShowMessageBox("ノートが選択されていません。", "ReaperLyricTools - エラー", 0)
          else
            -- 選択されたノートの歌詞から母音を抽出
            local vowel = ""
            if selected_note_lyric and selected_note_lyric ~= "" then
              vowel = extract_vowel(selected_note_lyric)
            end
            
            if vowel == "" then
              reaper.ShowMessageBox("選択されたノートに歌詞がありません。", "ReaperLyricTools - エラー", 0)
            else
              -- 履歴に現在の状態を保存
              push_lyric_history()
              -- 母音を挿入位置に追加
              local base_pos
              if last_selected_note_index ~= nil then
                base_pos = last_selected_note_index + 1
              else
                base_pos = note_count
              end
              local insert_pos = math.min(math.max(base_pos, 0), #lyric_chars)
              
              -- 母音をユニット配列に変換
              local insert_units = build_lyric_units_from_text(vowel)
              
              -- 既存ユニットに対して、母音を挿入
              local new_units = {}
              for i = 1, insert_pos do
                table.insert(new_units, lyric_chars[i])
              end
              for i = 1, #insert_units do
                table.insert(new_units, insert_units[i])
              end
              for i = insert_pos + 1, #lyric_chars do
                table.insert(new_units, lyric_chars[i])
              end
              
              lyric_chars = new_units
              
              -- ユニット配列からテキストを再構成して一括反映
              local new_text = table.concat(lyric_chars, "")
              apply_lyrics_text_to_all(new_text)
            end
          end
        end
      end
    elseif mx >= undo_btn_x and mx <= (undo_btn_x + undo_btn_w)
       and my >= undo_btn_y and my <= (undo_btn_y + undo_btn_h) then
      -- Undo（歌詞）ボタン
      if lyric_history_index > 1 then
        lyric_history_index = lyric_history_index - 1
        local state = lyric_history[lyric_history_index]
        if state and state.text ~= nil then
          apply_lyrics_text_to_all(state.text)
        end
      else
        reaper.ShowMessageBox("これ以上戻せる履歴がありません。", "ReaperLyricTools - Undo", 0)
      end
    elseif mx >= redo_btn_x and mx <= (redo_btn_x + redo_btn_w)
       and my >= redo_btn_y and my <= (redo_btn_y + redo_btn_h) then
      -- Redo（歌詞）ボタン
      if lyric_history_index > 0 and lyric_history_index < #lyric_history then
        lyric_history_index = lyric_history_index + 1
        local state = lyric_history[lyric_history_index]
        if state and state.text ~= nil then
          apply_lyrics_text_to_all(state.text)
        end
      else
        reaper.ShowMessageBox("やり直せる履歴がありません。", "ReaperLyricTools - Redo", 0)
      end
    end
  end
  last_mouse_cap = mcap

  -- 停止したいときは「ウィンドウを閉じる」「Esc」、
  -- または「Actions → Terminate instances of script」等で止めてください。
  reaper.defer(main_loop)
end

------------------------------------------------------------
-- スクリプト開始
------------------------------------------------------------

local function init()
  local created = ensure_lyrics_file()
  if created then
    reaper.ShowMessageBox(
      "歌詞用テキストファイルを作成しました。\n\n" ..
      lyrics_file_path ..
      "\n\nこのファイルをテキストエディタで開いて、日本語歌詞を入力し保存してください。\n" ..
      "保存するたびに、ノートへの歌詞割り当てが自動更新されます。",
      "ReaperLyricTools - 歌詞ファイル作成",
      0
    )
  end

  -- 最初の読み込み
  lyric_text = read_lyrics_file()
  update_lyric_chars()
  last_lyric_text = lyric_text

  -- メインループ開始
  main_loop()
end

------------------------------------------------------------
-- 実行
------------------------------------------------------------

init()