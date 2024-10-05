obs = obslua

-- 前のシーン
local previous_scene_name = nil

-- 全てのオーディオメディアのリスト
-- トランジションの開始時に遷移前と遷移後のオーディオメディアを集めてトランジション終了後にソースをまとめて解放する。
-- トランジション時に同じ参照のメディアソースがある場合、そのメディアソースがフェードしないようにするため、
-- fade_out.audio_list と　fade_in.audio_list から共通のメディアソースを削除する必要があるので
-- この変数にまとめておく
local all_audio_list = {}

local fade_out = {
    -- メディアソースのリスト
    audio_list = {},
    -- フェードのステップのリスト 
    -- audio_nameがkey
    step_list = {},
    -- フェードする前の音量のリスト
    -- audio_nameがkey
    volume_list = {}
}

local fade_in = {
    -- メディアソースのリスト
    audio_list = {},
    -- フェードのステップのリスト
    -- audio_nameがkey
    step_list = {},
    -- フェードする前の音量のリスト
    -- audio_nameがkey
    volume_list = {}
}

-- 現在のフェード時間
-- ユーザーが設定したfade_duration_tableと照らし合わせて変化する
local current_fade_duration = 0

-- フェードアウト・フェードインする間隔(ミリ秒)のテーブル
-- ユーザーが設定できる
-- キーはトランジション名
local fade_duration_table = {}

-- フェードの単位
local FADE_UNIT = 100

-- トランジション名のリスト
local transition_name_list = {}

-- シグナルハンドラの接続を管理する変数
-- obs.signal_handler_connectによって接続されたシグナルハンドラの情報が格納される
-- スクリプトがアンロードされる際に、適切に切断するために使用される
local signal_handler_list = {}

-- グローバルなsettings
local global_settings = nil


-- audioをaudio_nameに変換する
local audio_to_audio_name = function (audio)
    return obs.obs_source_get_name(audio)
end


-- audioのリストのログを出力
local log_audio_list = function (title, audio_list)
    print(title)
    for _, audio in ipairs(audio_list) do
        local audio_name = obs.obs_source_get_name(audio)
        print("  ソース名: " .. audio_name)
    end
end


-- フェードのステップのリストのログを出力
local log_step_list = function (title, step_list)
    print(title)
    for audio_name, step in pairs(step_list) do
        print("  " .. audio_name .. " :" .. step)
    end
end


-- 音量にリストのログを出力
local log_volume_list = function (title, volume_list)
    print(title)
    for audio_name, volume in pairs(volume_list) do
        print("  " .. audio_name .. " :" .. volume)
    end
end


function script_description()
    return "シーン遷移時に音声ソースのフェードイン・フェードアウトを実行します。\n\n" ..
           "トランジション毎にフェードの長さを変えられます。\n\n" ..
           "トランジションを増やしたらスクリプトを更新するとリストにトランジションが追加されます。"
end


-- イベントの登録と解除
-- 起動時はソースが全てロードされる前にこの関数が呼び出されてしまうので、
-- on_eventのOBS_FRONTEND_EVENT_FINISHED_LOADINGを検知して初期化する。
-- 逆にスクリプトを初めてロードしたり、リロードされた時はon_eventは発火しないのでこの関数で初期化する。
-- スクリプトがロード・リロードしている頃にはソースはロードされているので正しく初期化できる。
function script_load(settings)

    print("-----script_load-----")

    global_settings = settings

    -- 初期化処理をする
    init()

    -- イベントのコールバックを登録
    obs.obs_frontend_add_event_callback(on_event)

end


function init()

    print("-----init-----")

    -- previous_scene_nameを更新
    init_previous_scene_name()

    -- transition_name_listを更新
    update_transition_name_list()

    -- fade_duration_tableを更新
    update_fade_duration_table(global_settings)

    -- トランジションが開始したら発火するコールバックを登録
    local transition_list =  obs.obs_frontend_get_transitions()

    for _, transition_source in ipairs(transition_list) do

        local signal_handler = obs.obs_source_get_signal_handler(transition_source)
        table.insert(signal_handler_list, signal_handler)

        obs.signal_handler_connect(
            signal_handler,
            "transition_start",
            on_transition_start
        )

    end

    -- メモリを解放
    obs.source_list_release(transition_list)

end


function script_unload()

    print("-----script_unload-----")

    -- シグナルハンドラを解除
    for _, signal_handler in ipairs(signal_handler_list) do
        obs.signal_handler_disconnect(signal_handler)
    end

    -- イベントのコールバックを削除
    obs.obs_frontend_remove_event_callback(on_event)
    
end


-- スクリプトの設定が変更されたときに呼ばれる関数
function script_update(settings)
    print("-----script_update-----")
    update_fade_duration_table(settings)
end


function update_transition_name_list()

    print("-----update_transition_list-----")

    -- transition_name_listを初期化
    transition_name_list = {}

    local transition_list =  obs.obs_frontend_get_transitions()

    for _, transition_source in ipairs(transition_list) do
        local transition_name = obs.obs_source_get_name(transition_source)
        table.insert(transition_name_list, transition_name)
        print("  " .. transition_name)
    end

    -- メモリを解放
    obs.source_list_release(transition_list)

end


function update_fade_duration_table(settings)

    for _, transition_name in ipairs(transition_name_list) do
        fade_duration_table[transition_name] = obs.obs_data_get_int(
            settings,
            "fade_duration_" .. transition_name
        )
    end

    print("[fade_duration_table]")
    for transition_name, fade in pairs(fade_duration_table) do
        print("  " .. transition_name .. ":" .. fade .. "ms")
    end

end


-- スクリプトのプロパティを定義する関数
function script_properties()

    print("-----script_properties-----")

    local props = obs.obs_properties_create()

    -- transition_name_listを初期化しリストのUIを作成
    transition_name_list = {}

    local transition_list =  obs.obs_frontend_get_transitions()

    for _, transition_source in ipairs(transition_list) do
        local transition_name = obs.obs_source_get_name(transition_source)
        table.insert(transition_name_list, transition_name)
        print("  " .. transition_name)
    end

    -- メモリを解放
    obs.source_list_release(transition_list)

    for _, transition_name in pairs(transition_name_list) do

        -- トランジションごとにプロパティを追加
        local group = obs.obs_properties_create()

        -- フェード時間
        obs.obs_properties_add_int(
            group,
            "fade_duration_" .. transition_name,
            "フェード時間 (ミリ秒)",
            0, -- 最小値
            10000, -- 最大値
            10 -- ステップ
        )

        -- 追加されたトランジショングループをプロパティに追加
        obs.obs_properties_add_group(
            props,
            "transition_group_" .. transition_name,
            transition_name,
            obs.OBS_GROUP_NORMAL,
            group
        )

    end

    return props
end


function init_previous_scene_name()

    print("init_first_scene")

    -- 既に初期化されていたらタイマーを削除して返す
    if previous_scene_name then
        return
    end

    update_previous_scene_name()

end


function update_previous_scene_name()
    
    local previous_scene = obs.obs_frontend_get_current_scene()

    if previous_scene then
        previous_scene_name = obs.obs_source_get_name(previous_scene)
        print("開始シーン: " .. previous_scene_name)
        -- メモリ解放
        obs.obs_source_release(previous_scene)
    else
        print("開始シーンをロードできませんでした")
    end

end


function on_transition_start(_)

    print("-----on_transition_start------")

    -- 現在のシーンを取得
    local current_scene = obs.obs_frontend_get_current_scene()

    if current_scene == nil then
        return
    end

    local current_scene_name = obs.obs_source_get_name(current_scene)

    if current_scene_name == previous_scene_name then
        return
    end

    -- 現在のトランジションを取得
    local current_trannsition = obs.obs_frontend_get_current_transition()
    local current_trannsition_name = obs.obs_source_get_name(current_trannsition)

    -- トランジションに対応したフェード時間を取得
    current_fade_duration = fade_duration_table[current_trannsition_name]

    if current_fade_duration == nil then
        current_fade_duration = 0
    end

    -- メモリを解放
    obs.obs_source_release(current_trannsition)

    print("トランジション: " .. previous_scene_name .. " -> " .. current_scene_name .. "(" .. current_trannsition_name .. ")")
    print("現在のフェード時間: " .. current_fade_duration .. "ms")

    -- 各々のオーディオメディアのリストを取得
    local previous_audio_list = get_audio_list(previous_scene_name)
    local current_audio_list = get_audio_list(current_scene_name)

    -- オーディオメディアのリストを結合して後でまとめて解放する
    all_audio_list = merge_tables(previous_audio_list, current_audio_list)

    -- それぞれのリストに共通の要素を削除する
    -- 削除することでシーン間で同じ参照を持つオーディオメディアをフェードしない様にする
    fade_out.audio_list = subtract_tables(
        previous_audio_list,
        current_audio_list,
        audio_to_audio_name
    )

    fade_in.audio_list = subtract_tables(
        current_audio_list,
        previous_audio_list,
        audio_to_audio_name
    )

    log_audio_list("[correct_preivous_audio_list]", fade_out.audio_list)
    log_audio_list("[correct_current_audio_list]", fade_in.audio_list)

    -- 前のシーンのメディアソースをフェードアウト
    if fade_out.audio_list and #fade_out.audio_list > 0 then
        start_fade_out()
    end

    -- 現在のシーンのメディアソースをフェードイン
    if fade_in.audio_list and #fade_in.audio_list > 0 then
        start_fade_in()
    end

    -- 現在のシーン名を次回用に保存
    previous_scene_name = current_scene_name

    -- メモリを解放
    obs.obs_source_release(current_scene)

end


function on_transition_stop(_)

    print("on_transition_stop")

    -- メモリを解放
    for _, audio in pairs(all_audio_list) do
        obs.obs_source_release(audio)
    end

    all_audio_list = {}

end


-- フロントエンドイベントを検知する関数
function on_event(event)

    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        print("-----OBS_FRONTEND_EVENT_FINISHED_LOADING-----")
        -- 初期化処理
        init()
    end

end


-- シーン名からシーンを取得
function get_scene_by_scene_name(scene_name)

    local source = obs.obs_get_source_by_name(scene_name)

    if source == nil then
        print("シーンが見つかりません: " .. scene_name)
        return nil
    else
        return obs.obs_scene_from_source(source)
    end

end


function get_audio_list(scene_name)

    local media_sources = {}

    local scene = get_scene_by_scene_name(scene_name)

    if scene == nil then
        print("指定されたシーンが見つかりません: " .. scene_name)
        return media_sources
    end

    -- シーンのソースリストを取得
    local scene_items = obs.obs_scene_enum_items(scene)

    if scene_items == nil or #scene_items == 0 then
        print(scene_name .. "内のソースアイテムが見つかりませんでした")
        -- メモリを解放
        obs.obs_scene_release(scene)
        return media_sources
    end
    
    for _, scene_item in ipairs(scene_items) do

        local source = obs.obs_sceneitem_get_source(scene_item)
        local source_id = obs.obs_source_get_id(source)
        local media_source_name = obs.obs_source_get_name(source)

        if media_source_name == nil then
            print("ソース名が取得できませんでした")
        -- メディアソース（音声ファイルやビデオファイル）のIDは "ffmpeg_source"
        elseif source_id == "ffmpeg_source" then
            table.insert(media_sources, source)
        end

    end

    -- メモリを解放
    obs.obs_scene_release(scene)
    obs.sceneitem_list_release(scene_items)

    return media_sources

end


-- フェードアウト開始の関数
function start_fade_out()

    -- 既存のフェードアウト処理をキャンセル
    obs.timer_remove(fade_out_audio)

    for i = #fade_out.audio_list, 1, -1 do

        local audio = fade_out.audio_list[i]
        local audio_name = obs.obs_source_get_name(audio)

        -- フェードインが完了していたら
        if fade_in.volume_list[audio_name] == nil then

            local target_volume

            if fade_out.volume_list[audio_name] then
                -- 保存してた音量を目標値にする
                target_volume = fade_out.volume_list[audio_name]
            else
                -- 元々の音量を保存しておく
                -- トランジション完了後にフェードアウトしたオーディオメディアの元々の音量に戻す
                target_volume = obs.obs_source_get_volume(audio)
                fade_out.volume_list[audio_name] = target_volume
            end

            -- フェードアウトのステップを保存
            local fade_out_step = target_volume / (current_fade_duration / FADE_UNIT)
            fade_out.step_list[audio_name] = fade_out_step

        else
            -- フェードアウトしなくていいなら
            table.remove(fade_out.audio_list, i)
        end
    end

    log_step_list("[フェードアウトのステップ]", fade_out.step_list)
    log_volume_list("[フェードアウト前の音量]", fade_out.volume_list)

    -- 100msごとにコールバックを実行
    obs.timer_add(fade_out_audio, FADE_UNIT)

end


function fade_out_audio()

    print("-----fade_out_audio-----")

    for i = #fade_out.audio_list, 1, -1 do

        local audio = fade_out.audio_list[i]
        local audio_name = obs.obs_source_get_name(audio)

        local fade_out_step = fade_out.step_list[audio_name]

        local current_volume = obs.obs_source_get_volume(audio)

        print("  音量(前): " .. current_volume)

        current_volume = math.max(current_volume - fade_out_step, 0)
        obs.obs_source_set_volume(audio, current_volume)

        print("  音量(後): " .. current_volume)

        -- 音量が0になったらリストから削除  
        if current_volume == 0 then

            print("音量が0になりました")

            -- オーディオを停止して元の音量に戻す
            obs.obs_source_media_play_pause(audio, true)

            obs.obs_source_set_volume(
                audio,
                fade_out.volume_list[audio_name]
            )

            table.remove(fade_out.audio_list, i)
            fade_out.step_list[audio_name] = nil
            fade_out.volume_list[audio_name] = nil

        end

    end

    -- 全てのメディアソースの音量が0になったら非同期処理を終了
    if #fade_out.audio_list == 0 then
        print("フェードアウト終了")
        obs.timer_remove(fade_out_audio)
    end

end


function start_fade_in()

    -- 既存のフェードイン処理をキャンセル
    obs.timer_remove(fade_in_audio)

    for i = #fade_in.audio_list, 1, -1 do

        local audio = fade_in.audio_list[i]
        local audio_name = obs.obs_source_get_name(audio)

        -- フェードアウトが完了していたら
        if fade_out.volume_list[audio_name] == nil then

            local target_volume

            -- フェードインの途中だったらvolume_after_fade_in_listを更新しない
            if fade_in.volume_list[audio_name] then
                -- 保存されていた音量を目標値にする
                target_volume = fade_in.volume_list[audio_name]
            else
                -- 元々の音量を保存しておく
                -- トランジション完了後にフェードインしたオーディオメディアの元々の音量に戻す
                target_volume = obs.obs_source_get_volume(audio)
                fade_in.volume_list[audio_name] = target_volume
            end

            -- フェードインのステップを保存
            local fade_in_step = target_volume / (current_fade_duration / FADE_UNIT)
            fade_in.step_list[audio_name] = fade_in_step

            -- その後音量を0にしておく
            obs.obs_source_set_volume(audio, 0)

            -- オーディオメディアを再生する
            obs.obs_source_media_restart(audio)
            
        else
            table.remove(fade_in.audio_list, i)
        end

    end

    log_step_list("[フェードインのステップ]", fade_in.step_list)
    log_volume_list("[フェードアウト前の音量]", fade_in.volume_list)

    -- 100msごとにコールバックを実行
    obs.timer_add(fade_in_audio, FADE_UNIT)

end


function fade_in_audio()

    print("-----fade_in_audio-----")

    for i = #fade_in.audio_list, 1, -1 do

        local audio = fade_in.audio_list[i]
        local audio_name = obs.obs_source_get_name(audio)

        local fade_in_step = fade_in.step_list[audio_name]

        local target_volume = fade_in.volume_list[audio_name]
        local current_volume = obs.obs_source_get_volume(audio)

        print("  音量(前): " .. current_volume)

        current_volume = math.min(current_volume + fade_in_step, target_volume)
        obs.obs_source_set_volume(audio, current_volume)

        print("  音量(後): " .. current_volume)

        -- 音量が目標値 になったらリストから削除  
        if current_volume == target_volume then

            print("音量が目標値になりました")

            table.remove(fade_in.audio_list, i)
            fade_in.step_list[audio_name] = nil
            fade_in.volume_list[audio_name] = nil

        end

    end

    -- 全てのメディアソースの音量が目標値になったら非同期処理を終了
    if #fade_in.audio_list == 0 then
        print("フェードイン終了")
        obs.timer_remove(fade_in_audio)
    end

end


function merge_tables(t1, t2)

    local merged = {}

    for _, v in ipairs(t1) do
        table.insert(merged, v)
    end

    for _, v in ipairs(t2) do
        table.insert(merged, v)
    end

    return merged

end


-- t1からt2の要素を引いて返す
-- 比較用の無名関数を引数として受け取る
function subtract_tables(t1, t2, comparator)

    local result = {}
    local set = {}

    for _, item in ipairs(t2) do
        local key = comparator(item)
        set[key] = true
    end

    -- t1の要素がt2に含まれていない場合だけ結果に追加
    for _, item in ipairs(t1) do
        local key = comparator(item)
        if not set[key] then
            table.insert(result, item)
        end
    end

    return result

end

