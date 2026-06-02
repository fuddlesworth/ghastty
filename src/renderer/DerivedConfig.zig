//! The renderer's derived configuration. Hoisted out of
//! `generic.zig`'s `Renderer(GraphicsAPI)` so it is a single canonical
//! type shared by every backend instantiation (and, once the renderer
//! becomes a runtime-selected union, by all variants at once) rather
//! than a distinct nested type per backend.
//!
//! It is "derived" because it copies the subset of `Config` the
//! renderer needs into an arena, so we don't pass `Config` pointers
//! around (which makes memory management a pain). It does not depend on
//! the graphics API.

const std = @import("std");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const link = @import("link.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    font_thicken: bool,
    font_thicken_strength: u8,
    font_features: std.ArrayListUnmanaged([:0]const u8),
    font_styles: font.CodepointResolver.StyleStatus,
    font_shaping_break: configpkg.FontShapingBreak,
    cursor_color: ?configpkg.Config.TerminalColor,
    cursor_opacity: f64,
    cursor_text: ?configpkg.Config.TerminalColor,
    background: terminal.color.RGB,
    background_opacity: f64,
    background_opacity_cells: bool,
    foreground: terminal.color.RGB,
    selection_background: ?configpkg.Config.TerminalColor,
    selection_foreground: ?configpkg.Config.TerminalColor,
    search_background: configpkg.Config.TerminalColor,
    search_foreground: configpkg.Config.TerminalColor,
    search_selected_background: configpkg.Config.TerminalColor,
    search_selected_foreground: configpkg.Config.TerminalColor,
    bold_color: ?terminal.Style.BoldColor,
    faint_opacity: u8,
    min_contrast: f32,
    padding_color: configpkg.WindowPaddingColor,
    custom_shaders: configpkg.RepeatablePath,
    bg_image: ?configpkg.Path,
    bg_image_opacity: f32,
    bg_image_position: configpkg.BackgroundImagePosition,
    bg_image_fit: configpkg.BackgroundImageFit,
    bg_image_repeat: bool,
    links: link.Set,
    vsync: bool,
    colorspace: configpkg.Config.WindowColorspace,
    blending: configpkg.Config.AlphaBlending,
    background_blur: configpkg.Config.BackgroundBlur,
    scroll_to_bottom_on_output: bool,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Copy our shaders
        const custom_shaders = try config.@"custom-shader".clone(alloc);

        // Copy our background image
        const bg_image =
            if (config.@"background-image") |bg|
                try bg.clone(alloc)
            else
                null;

        // Copy our font features
        const font_features = try config.@"font-feature".clone(alloc);

        // Get our font styles
        var font_styles = font.CodepointResolver.StyleStatus.initFill(true);
        font_styles.set(.bold, config.@"font-style-bold" != .false);
        font_styles.set(.italic, config.@"font-style-italic" != .false);
        font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

        // Our link configs
        const links = try link.Set.fromConfig(
            alloc,
            config.link.links.items,
        );

        return .{
            .background_opacity = @max(0, @min(1, config.@"background-opacity")),
            .background_opacity_cells = config.@"background-opacity-cells",
            .font_thicken = config.@"font-thicken",
            .font_thicken_strength = config.@"font-thicken-strength",
            .font_features = font_features.list,
            .font_styles = font_styles,
            .font_shaping_break = config.@"font-shaping-break",

            .cursor_color = config.@"cursor-color",
            .cursor_text = config.@"cursor-text",
            .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),

            .background = config.background.toTerminalRGB(),
            .foreground = config.foreground.toTerminalRGB(),
            .bold_color = if (config.@"bold-color") |b| b.toTerminal() else null,
            .faint_opacity = @intFromFloat(@ceil(config.@"faint-opacity" * 255)),

            .min_contrast = @floatCast(config.@"minimum-contrast"),
            .padding_color = config.@"window-padding-color",

            .selection_background = config.@"selection-background",
            .selection_foreground = config.@"selection-foreground",
            .search_background = config.@"search-background",
            .search_foreground = config.@"search-foreground",
            .search_selected_background = config.@"search-selected-background",
            .search_selected_foreground = config.@"search-selected-foreground",

            .custom_shaders = custom_shaders,
            .bg_image = bg_image,
            .bg_image_opacity = config.@"background-image-opacity",
            .bg_image_position = config.@"background-image-position",
            .bg_image_fit = config.@"background-image-fit",
            .bg_image_repeat = config.@"background-image-repeat",
            .links = links,
            .vsync = config.@"window-vsync",
            .colorspace = config.@"window-colorspace",
            .blending = config.@"alpha-blending",
            .background_blur = config.@"background-blur",
            .scroll_to_bottom_on_output = config.@"scroll-to-bottom".output,
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        const alloc = self.arena.allocator();
        self.links.deinit(alloc);
        self.arena.deinit();
    }
};
