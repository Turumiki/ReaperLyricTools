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
local function update_lyric_chars()
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
  gfx.drawstr("削除 (ノート)")

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
      local ok, ret = reaper.GetUserInputs(
        "次に挿入される歌詞を追加",
        1,
        "挿入する文字（1行・数文字を推奨）:",
        ""
      )
      if ok and ret ~= "" then
        -- 歌詞ユニット配列が未構築なら構築
        if not lyric_chars or #lyric_chars == 0 then
          lyric_text = read_lyrics_file()
          update_lyric_chars()
          last_lyric_text = lyric_text
        end

        -- アクティブテイクから現在のノート情報を取得
        local editor = reaper.MIDIEditor_GetActive()
        local note_count = 0
        local last_selected_note_index = nil
        if editor then
          local take = reaper.MIDIEditor_GetTake(editor)
          if take then
            local _, nc = reaper.MIDI_CountEvts(take)
            note_count = nc or 0
            -- 選択されているノートのうち、インデックスが最大のものを探す
            for i = 0, note_count - 1 do
              local ok, sel = reaper.MIDI_GetNote(take, i)
              if ok and sel then
                last_selected_note_index = i
              end
            end
          end
        end

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

        -- ユニット配列からテキストを再構成してファイルに書き戻す（改行なし・直列）
        local new_text = table.concat(lyric_chars, "")
        local f = io.open(lyrics_file_path, "w")
        if f then
          f:write(new_text)
          f:close()
        end

        -- 内部状態も更新
        lyric_text = new_text
        last_lyric_text = lyric_text
        -- 歌詞が変わったので、ノート配列が安定したタイミングで再反映される
        last_note_signature = nil
        last_note_change_time = 0
      end
    elseif mx >= del_btn_x and mx <= (del_btn_x + del_btn_w)
       and my >= del_btn_y and my <= (del_btn_y + del_btn_h) then
      -- 削除ボタン: 次に挿入される位置から、指定ノート数ぶん歌詞ユニットを削除
      local ok, ret = reaper.GetUserInputs(
        "歌詞ユニットの削除",
        1,
        "削除するノート数（整数、例: 1〜10）:",
        "1"
      )
      if ok and ret ~= "" then
        local count = tonumber(ret)
        if count and count > 0 then
          -- 歌詞ユニット配列が未構築なら構築
          if not lyric_chars or #lyric_chars == 0 then
            lyric_text = read_lyrics_file()
            update_lyric_chars()
            last_lyric_text = lyric_text
          end

          local editor = reaper.MIDIEditor_GetActive()
          local note_count = 0
          local last_selected_note_index = nil
          if editor then
            local take = reaper.MIDIEditor_GetTake(editor)
            if take then
              local _, nc = reaper.MIDI_CountEvts(take)
              note_count = nc or 0
              for i = 0, note_count - 1 do
                local ok_note, sel = reaper.MIDI_GetNote(take, i)
                if ok_note and sel then
                  last_selected_note_index = i
                end
              end
            end
          end

          local total_units = #lyric_chars
          local base_pos
          if last_selected_note_index ~= nil then
            base_pos = last_selected_note_index + 1
          else
            base_pos = note_count
          end
          -- 削除開始位置（1-based）
          local del_start = math.min(math.max(base_pos + 1, 1), total_units + 1)
          local del_end = math.min(del_start - 1 + count, total_units)

          if del_start <= total_units and del_start <= del_end then
            local new_units = {}
            for i = 1, total_units do
              if i < del_start or i > del_end then
                table.insert(new_units, lyric_chars[i])
              end
            end
            lyric_chars = new_units

            local new_text = table.concat(lyric_chars, "")
            local f = io.open(lyrics_file_path, "w")
            if f then
              f:write(new_text)
              f:close()
            end

            lyric_text = new_text
            last_lyric_text = lyric_text
            last_note_signature = nil
            last_note_change_time = 0
          end
        end
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