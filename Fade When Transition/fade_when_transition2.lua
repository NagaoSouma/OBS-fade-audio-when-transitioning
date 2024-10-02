obs = obslua

-- 前のシーン
local previous_scene_name = nil

-- フェードアウトするメディアソースのリスト
local fade_out_audio_list = {}

-- 一度の呼び出しでフェードアウトする音量のリスト
local fade_out_step_list = {}

-- フェードアウトする間隔(ミリ秒)
local fade_out_duration = 1000

-- フェードアウトする前の音量
local volume_before_fade_out_list = {}

-- イベントの登録と解除
function script_load(settings)
    print("-----script_load-----")

    obs.signal_handler_connect(
        obs.obs_get_signal_handler(), 
        "source_show",
        on_source_show
    )

end

function on_source_show(calldata)
    local source = obs.calldata_source(calldata, "source")
    if source == nil then return end
    local source_id = obs.obs_source_get_id(source)
    print("source_id: " .. source_id)
end