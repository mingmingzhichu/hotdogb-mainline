#!/usr/bin/env python3
# Generate drivers/gpu/drm/panel/panel-samsung-sofef03f.c from the vendor DT node.
#
# The vendor on/off command arrays are replayed verbatim as a sequence of
# mipi_dsi_dcs_write_seq_multi() calls, so there is no chance of a typo in the
# 554-byte init sequence.  DSC parameters are decoded from the PPS packet.
import io, re, sys

NODE = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sofef03f_node.dts"
OUT = sys.argv[2] if len(sys.argv) > 2 else "panel-samsung-sofef03f.c"

s = io.open(NODE, encoding="utf-8", errors="replace").read()


def get_prop(name):
    m = re.search(r"%s\s*=\s*\[([^\]]+)\];" % re.escape(name), s)
    if not m:
        return None
    return [int(t, 16) for t in m.group(1).split() if re.fullmatch(r"[0-9a-fA-F]{2}", t)]


def parse_packets(arr):
    """Split a Qualcomm DSI command array into (cmd_bytes, wait_ms) packets."""
    out = []
    i = 0
    while i < len(arr):
        ptype = arr[i]
        if ptype not in (0x05, 0x39):
            raise SystemExit("unexpected packet type 0x%02x at %d" % (ptype, i))
        # header: type, last, vc, ack, wait(1), dlen(2, big endian)
        wait = arr[i + 4]
        dlen = (arr[i + 5] << 8) | arr[i + 6]
        payload = arr[i + 7:i + 7 + dlen]
        if len(payload) != dlen:
            raise SystemExit("truncated packet at %d (want %d got %d)"
                             % (i, dlen, len(payload)))
        out.append((payload, wait))
        i += 7 + dlen
    return out


on = get_prop("qcom,mdss-dsi-on-command")
off = get_prop("qcom,mdss-dsi-off-command")
if not on or not off:
    raise SystemExit("command arrays missing")

on_pkts = parse_packets(on)
off_pkts = parse_packets(off)

print("on: %d packets, %d bytes" % (len(on_pkts), len(on)))
print("off: %d packets" % len(off_pkts))

# --- DSC config decoded from the PPS packet -------------------------------
pps = None
for payload, _ in on_pkts:
    if payload[0] == 0x9e:
        pps = payload[1:]
assert pps and len(pps) == 128


def be16(k):
    return (pps[k] << 8) | pps[k + 1]


bpp_raw = pps[4] | ((pps[5] & 0x3) << 8) if False else (pps[5] | ((pps[4] & 0x3) << 8))
# PPS4 carries the flags + bpp high bits, PPS5 the low 8 bits
bpp = pps[5] | ((pps[4] & 0x03) << 8)
flags = pps[4]
vbr = (flags >> 2) & 1
simple422 = (flags >> 3) & 1
convert_rgb = (flags >> 4) & 1
block_pred = (flags >> 5) & 1

pic_h = be16(6); pic_w = be16(8)
slice_h = be16(10); slice_w = be16(12); chunk = be16(14)
xmit = be16(16); dec = be16(18); init_scale = be16(20)
scale_inc = be16(22); scale_dec = be16(24)
first_bpg = be16(26); nfl_bpg = be16(28); slice_bpg = be16(30)
init_off = be16(32); final_off = be16(34)
flat_min = pps[36]; flat_max = pps[37]
rc_model = be16(38); rc_edge = pps[40]
lim0 = pps[41]; lim1 = pps[42]
tgt_hi = pps[43] >> 4; tgt_lo = pps[43] & 0xf

thresh = list(pps[44:58])
ranges = []
for k in range(58, 58 + 30, 2):
    v = be16(k)
    ranges.append(((v >> 11) & 0x1f, (v >> 6) & 0x1f, v & 0x3f))

print("DSC: %dx%d slice %dx%d chunk %d bpp %d/%d bpc %d linebuf %d"
      % (pic_w, pic_h, slice_w, slice_h, chunk, bpp, 16, pps[3] >> 4, pps[3] & 0xf))

# --- emit C ---------------------------------------------------------------
L = []
w = L.append

w("// SPDX-License-Identifier: GPL-2.0-only")
w("/*")
w(" * Samsung SOFEF03F M FHD panel driver")
w(" *")
w(" * 1080x2400 command mode AMOLED with DSC, as found on the OnePlus 7T")
w(" * (hotdogb).  Initialisation sequence, timings and DSC parameters are")
w(" * taken verbatim from the vendor device tree node")
w(" * \"qcom,mdss_dsi_samsung_sofef03f_m_fhd_dsc_cmd\".")
w(" */")
w("")
w("#include <linux/backlight.h>")
w("#include <linux/delay.h>")
w("#include <linux/gpio/consumer.h>")
w("#include <linux/module.h>")
w("#include <linux/of.h>")
w("#include <linux/regulator/consumer.h>")
w("")
w("#include <video/mipi_display.h>")
w("")
w("#include <drm/drm_mipi_dsi.h>")
w("#include <drm/drm_modes.h>")
w("#include <drm/drm_panel.h>")
w("#include <drm/drm_probe_helper.h>")
w("")
w("struct sofef03f {")
w("\tstruct drm_panel panel;")
w("\tstruct mipi_dsi_device *dsi;")
w("\tstruct drm_dsc_config dsc;")
w("\tstruct regulator_bulk_data *supplies;")
w("\tstruct gpio_desc *reset_gpio;")
w("};")
w("")
w("/*")
w(" * The panel also needs the LCDB bias rails (lab/ibb) which come from the")
w(" * PM8150L LCDB block.  Mainline has no driver for that block, so we rely on")
w(" * the bootloader leaving them enabled (continuous splash).  Only vddio is")
w(" * modelled here.")
w(" */")
w("static const struct regulator_bulk_data sofef03f_supplies[] = {")
w("\t{ .supply = \"vddio\" },")
w("};")
w("")
w("static inline struct sofef03f *to_sofef03f(struct drm_panel *panel)")
w("{")
w("\treturn container_of(panel, struct sofef03f, panel);")
w("}")
w("")
w("static void sofef03f_reset(struct sofef03f *ctx)")
w("{")
w("\tgpiod_set_value_cansleep(ctx->reset_gpio, 0);")
w("\tusleep_range(5000, 6000);")
w("\tgpiod_set_value_cansleep(ctx->reset_gpio, 1);")
w("\tusleep_range(2000, 3000);")
w("\tgpiod_set_value_cansleep(ctx->reset_gpio, 0);")
w("\tusleep_range(12000, 13000);")
w("}")
w("")
w("/* 0x9e SET_PPS payload, copied verbatim from the vendor init sequence. */")
w("static const u8 sofef03f_pps[] = {")
w("\t0x9e,")
for k in range(0, 128, 12):
    chunk_bytes = pps[k:k + 12]
    w("\t" + " ".join("0x%02x," % b for b in chunk_bytes))
w("};")
w("")

def emit_packets(fn_name, pkts):
    w("static int %s(struct sofef03f *ctx)" % fn_name)
    w("{")
    w("\tstruct mipi_dsi_device *dsi = ctx->dsi;")
    w("\tstruct mipi_dsi_multi_context dsi_ctx = { .dsi = dsi };")
    w("\tint ret;")
    w("")
    w("\tdsi->mode_flags |= MIPI_DSI_MODE_LPM;")
    w("")
    for payload, wait in pkts:
        cmd, args = payload[0], payload[1:]
        if cmd == 0x9e:
            w("\t/* SET_PPS */")
            w("\tret = mipi_dsi_dcs_write_buffer(dsi, sofef03f_pps, sizeof(sofef03f_pps));")
            w("\tif (ret < 0)")
            w("\t\treturn ret;")
        elif not args:
            w("\tmipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x%02x);" % cmd)
        else:
            w("\tmipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x%02x, %s);"
              % (cmd, ", ".join("0x%02x" % a for a in args)))
        if wait:
            w("\tmipi_dsi_msleep(&dsi_ctx, %d);" % wait)
    w("")
    w("\treturn dsi_ctx.accum_err;")
    w("}")
    w("")

emit_packets("sofef03f_on", on_pkts)
emit_packets("sofef03f_off", off_pkts)

w("static int sofef03f_prepare(struct drm_panel *panel)")
w("{")
w("\tstruct sofef03f *ctx = to_sofef03f(panel);")
w("\tint ret;")
w("")
w("\tret = regulator_bulk_enable(ARRAY_SIZE(sofef03f_supplies), ctx->supplies);")
w("\tif (ret < 0)")
w("\t\treturn ret;")
w("")
w("\tsofef03f_reset(ctx);")
w("")
w("\tret = sofef03f_on(ctx);")
w("\tif (ret < 0) {")
w("\t\tgpiod_set_value_cansleep(ctx->reset_gpio, 1);")
w("\t\tregulator_bulk_disable(ARRAY_SIZE(sofef03f_supplies), ctx->supplies);")
w("\t}")
w("")
w("\treturn ret;")
w("}")
w("")
w("static int sofef03f_enable(struct drm_panel *panel)")
w("{")
w("\tstruct sofef03f *ctx = to_sofef03f(panel);")
w("\tstruct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };")
w("")
w("\tdsi_ctx.dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;")
w("\tmipi_dsi_dcs_set_display_on_multi(&dsi_ctx);")
w("\tdsi_ctx.dsi->mode_flags |= MIPI_DSI_MODE_LPM;")
w("")
w("\treturn dsi_ctx.accum_err;")
w("}")
w("")
w("static int sofef03f_disable(struct drm_panel *panel)")
w("{")
w("\tstruct sofef03f *ctx = to_sofef03f(panel);")
w("")
w("\tsofef03f_off(ctx);")
w("")
w("\treturn 0;")
w("}")
w("")
w("static int sofef03f_unprepare(struct drm_panel *panel)")
w("{")
w("\tstruct sofef03f *ctx = to_sofef03f(panel);")
w("")
w("\tregulator_bulk_disable(ARRAY_SIZE(sofef03f_supplies), ctx->supplies);")
w("")
w("\treturn 0;")
w("}")
w("")
w("static const struct drm_display_mode sofef03f_mode = {")
w("\t.clock = (1080 + 52 + 24 + 24) * (2400 + 1208 + 4 + 8) * 60 / 1000,")
w("")
w("\t.hdisplay = 1080,")
w("\t.hsync_start = 1080 + 52,")
w("\t.hsync_end = 1080 + 52 + 24,")
w("\t.htotal = 1080 + 52 + 24 + 24,")
w("")
w("\t.vdisplay = 2400,")
w("\t.vsync_start = 2400 + 1208,")
w("\t.vsync_end = 2400 + 1208 + 4,")
w("\t.vtotal = 2400 + 1208 + 4 + 8,")
w("")
w("\t.width_mm = 68,")
w("\t.height_mm = 145,")
w("")
w("\t.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,")
w("};")
w("")
w("static int sofef03f_get_modes(struct drm_panel *panel,")
w("\t\t\t      struct drm_connector *connector)")
w("{")
w("\treturn drm_connector_helper_get_modes_fixed(connector, &sofef03f_mode);")
w("}")
w("")
w("static const struct drm_panel_funcs sofef03f_panel_funcs = {")
w("\t.prepare = sofef03f_prepare,")
w("\t.enable = sofef03f_enable,")
w("\t.disable = sofef03f_disable,")
w("\t.unprepare = sofef03f_unprepare,")
w("\t.get_modes = sofef03f_get_modes,")
w("};")
w("")
w("static int sofef03f_bl_update_status(struct backlight_device *bl)")
w("{")
w("\tstruct mipi_dsi_device *dsi = bl_get_data(bl);")
w("\tu16 brightness = (u16)backlight_get_brightness(bl);")
w("\tint ret;")
w("")
w("\tdsi->mode_flags &= ~MIPI_DSI_MODE_LPM;")
w("\tret = mipi_dsi_dcs_set_display_brightness_large(dsi, brightness);")
w("\tdsi->mode_flags |= MIPI_DSI_MODE_LPM;")
w("")
w("\treturn ret;")
w("}")
w("")
w("static const struct backlight_ops sofef03f_bl_ops = {")
w("\t.update_status = sofef03f_bl_update_status,")
w("};")
w("")
w("static struct backlight_device *sofef03f_create_backlight(struct mipi_dsi_device *dsi)")
w("{")
w("\tstruct device *dev = &dsi->dev;")
w("\tconst struct backlight_properties props = {")
w("\t\t.type = BACKLIGHT_RAW,")
w("\t\t.brightness = 1024,")
w("\t\t.max_brightness = 2047,")
w("\t};")
w("")
w("\treturn devm_backlight_device_register(dev, dev_name(dev), dev, dsi,")
w("\t\t\t\t\t      &sofef03f_bl_ops, &props);")
w("}")
w("")
w("static int sofef03f_probe(struct mipi_dsi_device *dsi)")
w("{")
w("\tstruct device *dev = &dsi->dev;")
w("\tstruct sofef03f *ctx;")
w("\tint ret;")
w("")
w("\tctx = devm_drm_panel_alloc(dev, struct sofef03f, panel,")
w("\t\t\t\t   &sofef03f_panel_funcs, DRM_MODE_CONNECTOR_DSI);")
w("\tif (IS_ERR(ctx))")
w("\t\treturn PTR_ERR(ctx);")
w("")
w("\tret = devm_regulator_bulk_get_const(dev, ARRAY_SIZE(sofef03f_supplies),")
w("\t\t\t\t\t    sofef03f_supplies, &ctx->supplies);")
w("\tif (ret)")
w("\t\treturn dev_err_probe(dev, ret, \"Failed to get regulators\\n\");")
w("")
w("\tctx->reset_gpio = devm_gpiod_get(dev, \"reset\", GPIOD_OUT_HIGH);")
w("\tif (IS_ERR(ctx->reset_gpio))")
w("\t\treturn dev_err_probe(dev, PTR_ERR(ctx->reset_gpio),")
w("\t\t\t\t     \"Failed to get reset-gpios\\n\");")
w("")
w("\tctx->dsi = dsi;")
w("\tmipi_dsi_set_drvdata(dsi, ctx);")
w("")
w("\tdsi->lanes = 4;")
w("\tdsi->format = MIPI_DSI_FMT_RGB888;")
w("\t/* command mode: no MIPI_DSI_MODE_VIDEO */")
w("\tdsi->mode_flags = MIPI_DSI_CLOCK_NON_CONTINUOUS | MIPI_DSI_MODE_LPM;")
w("")
w("\t/* DSC is mandatory on this panel */")
w("\tctx->dsc.dsc_version_major = %d;" % (pps[0] >> 4))
w("\tctx->dsc.dsc_version_minor = %d;" % (pps[0] & 0xf))
w("\tctx->dsc.bits_per_component = %d;" % (pps[3] >> 4))
w("\tctx->dsc.line_buf_depth = %d;" % (pps[3] & 0xf))
w("\tctx->dsc.bits_per_pixel = %d; /* 4 fractional bits */" % bpp)
w("\tctx->dsc.block_pred_enable = %s;" % ("true" if block_pred else "false"))
w("\tctx->dsc.convert_rgb = %s;" % ("true" if convert_rgb else "false"))
w("\tctx->dsc.simple_422 = %s;" % ("true" if simple422 else "false"))
w("\tctx->dsc.vbr_enable = %s;" % ("true" if vbr else "false"))
w("\tctx->dsc.pic_width = %d;" % pic_w)
w("\tctx->dsc.pic_height = %d;" % pic_h)
w("\tctx->dsc.slice_width = %d;" % slice_w)
w("\tctx->dsc.slice_height = %d;" % slice_h)
w("\tctx->dsc.slice_count = %d;" % (pic_w // slice_w))
w("\tctx->dsc.slice_chunk_size = %d;" % chunk)
w("\tctx->dsc.initial_xmit_delay = %d;" % xmit)
w("\tctx->dsc.initial_dec_delay = %d;" % dec)
w("\tctx->dsc.initial_scale_value = %d;" % init_scale)
w("\tctx->dsc.scale_increment_interval = %d;" % scale_inc)
w("\tctx->dsc.scale_decrement_interval = %d;" % scale_dec)
w("\tctx->dsc.first_line_bpg_offset = %d;" % first_bpg)
w("\tctx->dsc.nfl_bpg_offset = %d;" % nfl_bpg)
w("\tctx->dsc.slice_bpg_offset = %d;" % slice_bpg)
w("\tctx->dsc.initial_offset = %d;" % init_off)
w("\tctx->dsc.final_offset = %d;" % final_off)
w("\tctx->dsc.flatness_min_qp = %d;" % flat_min)
w("\tctx->dsc.flatness_max_qp = %d;" % flat_max)
w("\tctx->dsc.rc_model_size = %d;" % rc_model)
w("\tctx->dsc.rc_edge_factor = %d;" % rc_edge)
w("\tctx->dsc.rc_quant_incr_limit0 = %d;" % lim0)
w("\tctx->dsc.rc_quant_incr_limit1 = %d;" % lim1)
w("\tctx->dsc.rc_tgt_offset_hi = %d;" % tgt_hi)
w("\tctx->dsc.rc_tgt_offset_lo = %d;" % tgt_lo)
w("")
w("\t/* rc_buf_thresh[] and rc_range_params[] come straight from the PPS */")
w("\tctx->dsc.rc_buf_thresh[0] = %s;" % ", ".join(str(x) for x in thresh[:7]))
w("\tctx->dsc.rc_buf_thresh[7] = %s;" % ", ".join(str(x) for x in thresh[7:]))
w("")
w("\tfor (int i = 0; i < %d; i++) {" % len(ranges))
w("\t\t/* min_qp, max_qp, bpg_offset */")
w("\t\tctx->dsc.rc_range_params[i].range_min_qp = sofef03f_ranges[i][0];")
w("\t\tctx->dsc.rc_range_params[i].range_max_qp = sofef03f_ranges[i][1];")
w("\t\tctx->dsc.rc_range_params[i].range_bpg_offset = sofef03f_ranges[i][2];")
w("\t}")
w("")
w("\tdsi->dsc = &ctx->dsc;")
w("")
w("\tctx->panel.prepare_prev_first = true;")
w("")
w("\tctx->panel.backlight = sofef03f_create_backlight(dsi);")
w("\tif (IS_ERR(ctx->panel.backlight))")
w("\t\treturn dev_err_probe(dev, PTR_ERR(ctx->panel.backlight),")
w("\t\t\t\t     \"Failed to create backlight\\n\");")
w("")
w("\tdrm_panel_add(&ctx->panel);")
w("")
w("\tret = mipi_dsi_attach(dsi);")
w("\tif (ret < 0) {")
w("\t\tdrm_panel_remove(&ctx->panel);")
w("\t\treturn ret;")
w("\t}")
w("")
w("\treturn 0;")
w("}")
w("")
w("static void sofef03f_remove(struct mipi_dsi_device *dsi)")
w("{")
w("\tstruct sofef03f *ctx = mipi_dsi_get_drvdata(dsi);")
w("\tint ret;")
w("")
w("\tret = mipi_dsi_detach(dsi);")
w("\tif (ret < 0)")
w("\t\tdev_err(&dsi->dev, \"Failed to detach from DSI host: %d\\n\", ret);")
w("")
w("\tdrm_panel_remove(&ctx->panel);")
w("}")
w("")
w("static const struct of_device_id sofef03f_of_match[] = {")
w("\t{ .compatible = \"samsung,sofef03f\" },")
w("\t{ /* sentinel */ }")
w("};")
w("MODULE_DEVICE_TABLE(of, sofef03f_of_match);")
w("")
w("static struct mipi_dsi_driver sofef03f_driver = {")
w("\t.probe = sofef03f_probe,")
w("\t.remove = sofef03f_remove,")
w("\t.driver = {")
w("\t\t.name = \"panel-samsung-sofef03f\",")
w("\t\t.of_match_table = sofef03f_of_match,")
w("\t},")
w("};")
w("module_mipi_dsi_driver(sofef03f_driver);")
w("")
w("MODULE_AUTHOR(\"hotdogb bring-up\");")
w("MODULE_DESCRIPTION(\"DRM driver for Samsung SOFEF03F M FHD DSC panel\");")
w("MODULE_LICENSE(\"GPL v2\");")
w("")

# insert the ranges table before probe
ranges_tbl = ["static const u8 sofef03f_ranges[%d][3] = {" % len(ranges)]
for mn, mx, bp in ranges:
    ranges_tbl.append("\t{ %d, %d, %d }," % (mn, mx, bp))
ranges_tbl.append("};")
ranges_tbl.append("")

txt = "\n".join(L)
anchor = "static int sofef03f_probe(struct mipi_dsi_device *dsi)"
txt = txt.replace(anchor, "\n".join(ranges_tbl) + "\n" + anchor, 1)

io.open(OUT, "w", encoding="utf-8").write(txt)
print("wrote", OUT, len(txt), "bytes")
