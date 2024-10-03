obs = obslua

-- 前のシーン
local previous_scene_name = nil

-- フェードアウトするメディアソースのリスト
local fade_out_audio_list = {}

-- 一度の呼び出しでフェードアウトする音量のリスト
local fade_out_step_list = {}

-- フェードアウトする前の音量
local volume_before_fade_out_list = {}


-- フェードインするメディアソースのリスト
local fade_in_audio_list = {}

-- 一度の呼び出しでフェードインする音量のリスト
local fade_in_step_list = {}

-- フェードインした後の音量
local volume_after_fade_in_list = {}


-- フェードアウト・フェードインする間隔(ミリ秒)
-- トランジション間隔が1000ミリ秒だとすると半分の500ミリ秒になる
-- 一応デフォルト値を持たせてるだけ
local fade_duration = 0


-- イベントの登録と解除
function script_load(settings)

    print("-----script_load-----")

    local transition_list =  obs.obs_frontend_get_transitions()

    for _, transition_source in ipairs(transition_list) do

        local signal_handler = obs.obs_source_get_signal_handler(transition_source)

        obs.signal_handler_connect(
            signal_handler,
            "transition_start",
            on_transition_start
        )

    end

    obs.timer_add(get_first_scene, 100)

end


-- スクリプトの設定が変更されたときに呼ばれる関数
function script_update(settings)
    fade_duration = obs.obs_data_get_int(
        settings,
        "user_settings_fade_duration"
    )
    if fade_duration == nil then
        fade_duration = 0
    end
end


-- スクリプトのプロパティを定義する関数
function script_properties()

    local props = obs.obs_properties_create()

    -- 整数型プロパティを追加
    obs.obs_properties_add_int(
        props, 
        "user_settings_fade_duration",
        "期間", 
        0, 10000, 5
    )  -- 最小0、最大1000、ステップ5

    return props
end


function get_first_scene()

    print("get_first_scene")

    -- 既に初期化されていたら返す
    if previous_scene_name then
        obs.timer_remove(get_first_scene)
        return
    end

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


function on_transition_start(source)
    print("-----on_transition_start------")

    -- 現在のシーンを取得
    local current_scene = obs.obs_frontend_get_current_scene()

    if current_scene == nil then return end

    local current_scene_name = obs.obs_source_get_name(current_scene)

    if current_scene_name == previous_scene_name then return end

    print("トランジション: " .. previous_scene_name .. " -> " .. current_scene_name)

    -- 前のシーンのメディアソースをフェードアウト
    local previous_audio_list = get_audio_list(previous_scene_name)
    start_fade_out(previous_audio_list)

    print("")

    -- 現在のシーンのメディアソースをフェードイン
    local current_audio_list = get_audio_list(current_scene_name)
    start_fade_in(current_audio_list)

    -- 現在のシーン名を次回用に保存
    previous_scene_name = current_scene_name

    -- メモリを解放
    obs.obs_source_release(current_scene)

end


function on_transition_stop(source)

    print("on_transition_stop")

    -- メモリを解放
    for _, audio in ipairs(fade_out_audio_list) do
        obs.obs_source_release(audio)
    end

    for _, audio in ipairs(fade_in_audio_list) do
        obs.obs_source_release(audio)
    end

end


-- イベントコールバック関数
function on_event(event)

    --[[
    if event == obs.OBS_FRONTEND_EVENT_TRANSITION_DURATION_CHANGED then
        print("-----OBS_FRONTEND_EVENT_TRANSITION_DURATION_CHANGED-----")
        fade_duration = obs.obs_frontend_get_transition_duration() / 2.5
        print("フェードアウトする間隔: " .. fade_duration .. "ミリ秒")
    end
    ]]

end


function get_scene_by_scene_name(scene_name)

    -- シーン名からシーンソースを取得
    local source = obs.obs_get_source_by_name(scene_name)

    if source == nil then
        print("シーンが見つかりません: " .. scene_name)
        return nil
    else
        -- シーンソースからシーンオブジェクトを取得
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

    -- シーンアイテムを1つずつ確認
    print("[" .. scene_name .. "内のソースアイテム]")
    
    for _, scene_item in ipairs(scene_items) do

        local source = obs.obs_sceneitem_get_source(scene_item)
        local source_id = obs.obs_source_get_id(source)
        local media_source_name = obs.obs_source_get_name(source)

        if media_source_name == nil then
            print("ソース名が取得できませんでした")
        -- メディアソース（音声ファイルやビデオファイル）のIDは "ffmpeg_source"
        elseif source_id == "ffmpeg_source" then
            print("  ソース名: " .. media_source_name .. ", ソースID: " .. source_id)
            table.insert(media_sources, source)
        end

    end

    -- メモリを解放
    obs.obs_scene_release(scene)
    obs.sceneitem_list_release(scene_items)

    return media_sources

end


-- フェードアウト開始の関数
function start_fade_out(audio_list)

    -- 既存のフェードアウト処理をキャンセル
    obs.timer_remove(fade_out_audio)

    fade_out_audio_list = audio_list

    for i = #fade_out_audio_list, 1, -1 do

        local audio = fade_out_audio_list[i]
        local audio_name = obs.obs_source_get_name(audio)

        -- フェードインが完了していたら
        if volume_after_fade_in_list[audio_name] == nil then

            local target_volume = 0

            if volume_before_fade_out_list[audio_name] then
                -- 保存してた音量を目標値にする
                target_volume = volume_before_fade_out_list[audio_name]

                -- フェードアウトのステップを保存
                local fade_out_step = target_volume / (fade_duration / 100)
                fade_out_step_list[audio_name] = fade_out_step
            else
                -- 元々の音量を保存しておく
                -- トランジション完了後にフェードアウトしたオーディオメディアの元々の音量に戻す
                local current_volume = obs.obs_source_get_volume(audio)
                volume_before_fade_out_list[audio_name] = current_volume

                -- フェードアウトのステップを保存
                local fade_out_step = current_volume / (fade_duration / 100)
                fade_out_step_list[audio_name] = fade_out_step

            end

        else
            -- フェードアウトしなくていいなら
            table.remove(fade_out_audio_list, i)
        end
    end

    print("[フェードアウトのステップ]")
    for key, value in pairs(fade_out_step_list) do
        print("  " .. key .. " :" .. value .. "ms")
    end

    print("[フェードアウト前の音量]")
    for key, value in pairs(volume_before_fade_out_list) do
        print("  " .. key .. " :" .. value .. "ms")
    end

    -- 100msごとにコールバックを実行
    obs.timer_add(fade_out_audio, 100)

end


function fade_out_audio()

    print("-----fade_out_audio-----")

    for i = #fade_out_audio_list, 1, -1 do

        local audio = fade_out_audio_list[i]
        local audio_name = obs.obs_source_get_name(audio)

        local fade_out_step = fade_out_step_list[audio_name]

        local current_volume = obs.obs_source_get_volume(audio)

        print("音量(前): " .. current_volume)

        current_volume = math.max(current_volume - fade_out_step, 0)
        obs.obs_source_set_volume(audio, current_volume)

        print("音量(後): " .. current_volume)

        -- 音量が0になったらリストから削除  
        if current_volume == 0 then

            print("音量が0になりました")

            -- オーディオを停止して元の音量に戻す
            obs.obs_source_media_play_pause(audio, true)

            obs.obs_source_set_volume(
                audio,
                volume_before_fade_out_list[audio_name]
            )

            table.remove(fade_out_audio_list, i)
            fade_out_step_list[audio_name] = nil
            volume_before_fade_out_list[audio_name] = nil

        end

    end

    -- 全てのメディアソースの音量が0になったら非同期処理を終了
    if #fade_out_audio_list == 0 then
        print("フェードアウト終了")
        obs.timer_remove(fade_out_audio)
    end

end


function start_fade_in(audio_list)

    -- 既存のフェードイン処理をキャンセル
    obs.timer_remove(fade_in_audio)

    fade_in_audio_list = audio_list

    for i = #fade_in_audio_list, 1, -1 do

        local audio = fade_in_audio_list[i]
        local audio_name = obs.obs_source_get_name(audio)

        -- それぞれフェードが完了していたら
        if volume_before_fade_out_list[audio_name] == nil then

            -- フェードインの途中だったらvolume_after_fade_in_listを更新しない
            if volume_after_fade_in_list[audio_name] then
                -- 保存されていた音量を目標値にする
               local target_volume = volume_after_fade_in_list[audio_name]

               -- フェードインのステップを保存
               local fade_in_step = target_volume / (fade_duration / 100)
               fade_in_step_list[audio_name] = fade_in_step

            else
                -- 元々の音量を保存しておく
                -- トランジション完了後にフェードインしたオーディオメディアの元々の音量に戻す
                local current_volume = obs.obs_source_get_volume(audio)
                volume_after_fade_in_list[audio_name] = current_volume

                -- フェードインのステップを保存
                local fade_in_step = current_volume / (fade_duration / 100)
                fade_in_step_list[audio_name] = fade_in_step

            end

            -- その後音量を0にしておく
            obs.obs_source_set_volume(audio, 0)

            -- オーディオメディアを再生する
            obs.obs_source_media_restart(audio)
            
        else
            table.remove(fade_in_audio_list, i)
        end

    end

    print("[フェードインのステップ]")
    for key, value in pairs(fade_in_step_list) do
        print("  " .. key .. " :" .. value .. "ms")
    end

    print("[フェードアウト前の音量]")
    for key, value in pairs(volume_after_fade_in_list) do
        print("  " .. key .. " :" .. value .. "ms")
    end

    -- 100msごとにコールバックを実行
    obs.timer_add(fade_in_audio, 100)

end


function fade_in_audio()

    print("-----fade_in_audio-----")

    for i = #fade_in_audio_list, 1, -1 do

        local audio = fade_in_audio_list[i]
        local audio_name = obs.obs_source_get_name(audio)

        local fade_in_step = fade_in_step_list[audio_name]

        local target_volume = volume_after_fade_in_list[audio_name]

        local current_volume = obs.obs_source_get_volume(audio)

        print("音量(前): " .. current_volume)

        current_volume = math.min(current_volume + fade_in_step, target_volume)
        obs.obs_source_set_volume(audio, current_volume)

        print("音量(後): " .. current_volume)

        -- 音量が目標値 になったらリストから削除  
        if current_volume == target_volume then

            print("音量が目標値になりました")

            table.remove(fade_in_audio_list, i)
            fade_in_step_list[audio_name] = nil
            volume_after_fade_in_list[audio_name] = nil

        end

    end

    -- 全てのメディアソースの音量が目標値になったら非同期処理を終了
    if #fade_in_audio_list == 0 then
        print("フェードイン終了")
        obs.timer_remove(fade_in_audio)
    end

end
