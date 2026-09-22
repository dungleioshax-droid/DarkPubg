sed -i -e '/for (int e = 0; e < 4; e++) {/c\
        uint64_t v = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);\
        if (!v || !ds_remote_invoke_noarg_on_main(process, v, "init")) {\
            ESPLog("esp ensure fail: border i=%d v=%llx", i, (unsigned long long)v);\
            return NO;\
        }\
        ds_perform_on_springboard_main(process, v, ds_remote_sel(process, "setBackgroundColor:"), clear, YES);\
        ds_remote_set_u64_on_main(process, v, "setHidden:", 1);\
        ds_remote_set_u64_on_main(process, v, "setUserInteractionEnabled:", 0);\
        uint64_t layer = ds_remote_get_object_on_main(process, v, "layer");\
        ds_remote_set_double_on_main(process, layer, "setBorderWidth:", kDSESPBorder);\
        uint64_t cgColor = ds_remote_get_u64_on_main(process, red, "CGColor");\
        if (cgColor) ds_perform_on_springboard_main(process, layer, ds_remote_sel(process, "setBorderColor:"), cgColor, YES);\
        ds_remote_set_double_on_main(process, layer, "setSpeed:", 999.0);\
        ds_perform_on_springboard_main(process, container, ds_remote_sel(process, "addSubview:"), v, YES);\
        g_espBorders[i][0] = v;\
        for (int e = 1; e < 4; e++) g_espBorders[i][e] = 0;\
' /home/dungle/DarkPubg/darksword/DSBridge.mm
