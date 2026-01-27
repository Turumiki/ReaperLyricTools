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

local lyric_text = ""          -- 現在ファイルから読み込んだ歌詞（複数行）
local lyric_chars = nil        -- ノートに割り当てる用の文字配列（改行除去済み）
local last_lyric_text = nil    -- 前フレームの歌詞テキスト
local last_note_count = -1     -- 前フレームのノート数

-- 歌詞ファイルのパス（現在のプロジェクトフォルダ）
local project_dir = reaper.GetProjectPath("")
local lyrics_file_path = project_dir .. "/ReaperLyricTools_lyrics.txt"

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

-- 歌詞テキストが変わったときに文字配列を更新
local function update_lyric_chars()
  local normalized = lyric_text:gsub("\r\n", "\n"):gsub("\r", "\n")
  -- ノート数に対応させるため、改行は歌詞割り当てからは除外（見た目用のみ）
  normalized = normalized:gsub("\n", "")
  lyric_chars = utf8_to_chars(normalized)
end

------------------------------------------------------------
-- メインループ（テキストファイル監視 + MIDI反映）
------------------------------------------------------------

local last_check_time = 0
local check_interval = 0.5  -- 秒ごとにファイルをチェック

local function main_loop()
  local now = reaper.time_precise()

  -- 一定間隔ごとに歌詞ファイルをチェック
  if now - last_check_time >= check_interval then
    last_check_time = now
    local file_text = read_lyrics_file()

    if file_text ~= lyric_text then
      lyric_text = file_text
      update_lyric_chars()
      last_lyric_text = lyric_text
      -- 歌詞が変わったので、ノート再割り当てをトリガする
      last_note_count = -1
    end
  end

  -- MIDI処理
  local editor = reaper.MIDIEditor_GetActive()
  if editor then
    local take = reaper.MIDIEditor_GetTake(editor)
    if take and lyric_chars and #lyric_chars > 0 then
      local _, note_count = reaper.MIDI_CountEvts(take)
      if note_count ~= last_note_count then
        reaper.MIDI_DisableSort(take)
        apply_lyrics_to_notes(take, lyric_chars)
        reaper.MIDI_Sort(take)
        last_note_count = note_count
      end
    end
  end

  -- 停止したいときは「Actions → Terminate instances of script」等で止めてください。
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