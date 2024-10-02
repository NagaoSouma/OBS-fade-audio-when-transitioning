obs = obslua


-- イベントの登録と解除
function script_load(settings)

    print("-----script_load-----")

    local transition_source = obs.obs_frontend_get_current_transition()

    if transition_source then

        local signal_handler = obs.obs_source_get_signal_handler(transition_source)

        obs.signal_handler_connect(
            signal_handler,
            "transition_start",
            on_transition_start
        )

    end

end


function on_transition_start(source)
    print("on_transition_start")
end