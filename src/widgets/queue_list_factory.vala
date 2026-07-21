// 编排列表 (queue_list) 的 SignalListItemFactory 构建器
//
// 从 window.vala setup_queue_list 中提取的 factory.setup/bind/unbind 回调
// 以及 render_queue_row 行渲染逻辑. 这是 setup_queue_list 中最容易隔离的部分:
//   - factory 回调不接触 [GtkChild] widget (queue_list/queue_stack/drop_indicator),
//     只操作 ListItem 内部的 row widget 和 ItemData 数据
//   - 通过 Hooks 委托回 Window 获取/修改 Window 私有状态 (dragging_item,
//     queue_update_depth 等) 和调用 Window 方法 (show_queue_context_menu,
//     update_preview, clear_tree_selection, set_drop_indicator)
//
// DropTarget 的 motion/drop 回调留在 Window: 它们需要 pick_row_box /
// reorder_queue_item / find_item_index 等 Window 私有方法, 与 ListStore
// 突变逻辑紧密耦合, 抽离价值低且接口会臃肿.

public class QueueListFactory : GLib.Object {

    // ─── Hooks 委托 ────────────────────────────────────────────────────
    // Window 把这些 callback 传给 create(), factory 回调中通过它们访问
    // Window 的私有状态/方法, 避免 QueueListFactory 直接持有 Window 引用.

    public delegate bool IsQueueUpdating ();
    public delegate ItemData? GetDraggingItem ();
    public delegate void SetDraggingItem (ItemData? item);
    public delegate void RenderRow (Gtk.ListItem list_item, ItemData data, Gtk.Label label, Gtk.Image icon);
    public delegate void ShowContextMenu (Gtk.Widget anchor, ItemData data, int pos, int x, int y);
    public delegate void UpdatePreview (ItemData data);
    public delegate void RefreshPreviewIfActive (ItemData data, uint position);
    public delegate void ClearTreeSelection ();
    public delegate void SetDropIndicator (Gtk.Widget? parent, bool after);

    // ─── 入口: 创建并返回配置好的 SignalListItemFactory ───────────────
    public static Gtk.SignalListItemFactory create (
        IsQueueUpdating is_queue_updating,
        GetDraggingItem get_dragging_item,
        SetDraggingItem set_dragging_item,
        RenderRow render_row,
        ShowContextMenu show_context_menu,
        UpdatePreview update_preview,
        RefreshPreviewIfActive refresh_preview_if_active,
        ClearTreeSelection clear_tree_selection,
        SetDropIndicator set_drop_indicator
    ) {
        var factory = new Gtk.SignalListItemFactory ();

        factory.setup.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;

            var icon = new Gtk.Image ();
            icon.add_css_class ("dim-label");

            var label = new Gtk.Label ("");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0;
            label.hexpand = true;

            // 拖拽排序手柄: 仅手柄作为拖拽源, 与行内已有的左/右键点击手势互不干扰.
            // 使用 Adwaita 原生的六点拖拽手柄图标 (list-drag-handle-symbolic), 而非
            // "更多操作" 省略号, 以贴合 GNOME 列表的视觉惯例.
            // 放在最左边: 避免与行最右侧的滚动指示器 (滚动条) 视觉/交互打架.
            var grip = new Gtk.Image.from_icon_name ("list-drag-handle-symbolic");
            grip.add_css_class ("dim-label");
            grip.add_css_class ("queue-drag-handle");
            grip.set_cursor (new Gdk.Cursor.from_name ("grab", null));

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            // 用 CSS padding 而非 margin: padding 在 allocation 之内, DropTarget 可覆盖整行;
            // margin 在 allocation 之外, 行间 margin 缝隙会成为 DropTarget 盲区 —— 落在缝隙
            // 的 drop 会被 queue_list 上的 end_drop 捕获并错误地移到列表末尾, 与指示线不一致.
            box.add_css_class ("queue-row-box");
            // 顺序: 拖拽手柄(最左) -> 文件类型图标 -> 文件名. 手柄居左可避开右侧滚动条.
            box.append (grip);
            box.append (icon);
            box.append (label);

            var drag = new Gtk.DragSource ();
            drag.set_actions (Gdk.DragAction.MOVE);
            // 记录鼠标按下点相对 box 的偏移, 用作浮动图标的 hot point,
            // 使拖动时按下位置"粘"在鼠标箭头处 (而不是整项居中于鼠标).
            double press_x = 0, press_y = 0;
            drag.prepare.connect ((s, gx, gy) => {
                // 模型正在突变 (删除/刷新) 时禁止发起拖拽, 避免拖拽中途数据错位
                if (is_queue_updating ()) return null;
                // gx/gy 是相对拖拽源 grip 的坐标, 转换成相对 box 的偏移.
                grip.translate_coordinates (box, gx, gy, out press_x, out press_y);
                var data = list_item.get_item () as ItemData;
                // 记录源项, 供 drop.motion 跳过"悬停在自身"的无效落点线
                set_dragging_item (data);
                // payload 携带 ItemData 引用, 落点处再按引用现算索引, 避免拖拽期间索引偏移
                return data != null ? new Gdk.ContentProvider.for_value (data) : null;
            });
            // 自定义拖拽图标: 用行快照, 避免 GTK 默认拖拽图标渲染路径去拉取 emoji
            // 彩色字体 (无 emoji 字体的环境下会刷 Pango "All font fallbacks failed").
            drag.drag_begin.connect ((d) => {
                var p = new Gtk.WidgetPaintable (box);
                Gtk.DragIcon.set_from_paintable (d, p, (int) press_x, (int) press_y);
            });
            grip.add_controller (drag);
            // 拖拽结束时无论是否落在有效位置, 都清掉落点指示线并复位源项记录
            drag.drag_end.connect (() => {
                set_drop_indicator (null, false);
                set_dragging_item (null);
            });

            // DropTarget 统一挂在 queue_list 上 (见 Window.setup_queue_list 中的 list_drop),
            // 不在每行 box 上单独挂, 避免行间缝隙导致 DropTarget 盲区.

            var right_click = new Gtk.GestureClick ();
            right_click.set_button (Gdk.BUTTON_SECONDARY);
            right_click.pressed.connect ((n_press, gx, gy) => {
                // 防御: 若队列模型正在突变 (删除/刷新), 忽略此次右键, 避免访问不稳定模型.
                if (is_queue_updating ()) return;

                var li = obj as Gtk.ListItem;
                if (li == null) return;
                uint pos = li.get_position ();
                // selection 同步 (unselect_all + select_item) 由 Window 在
                // show_context_menu 入口完成: factory 不持有 Gtk.SelectionModel 引用,
                // 把 selection 状态变更交由 Window 集中处理更简洁.
                var data = li.get_item () as ItemData;
                if (data != null) {
                    show_context_menu (box, data, (int) pos, (int) gx, (int) gy);
                }
            });
            box.add_controller (right_click);

            // 左键单击: 配合 MultiSelection, selection_changed 信号会自动处理预览更新.
            // 但点击"已选中的同一项"不会触发 selection_changed, 故此处主动重跑预览,
            // 保证每次点击都重新加载 (并回到顶部、重算内容长度, 避免残留滚动空白).
            var left_click = new Gtk.GestureClick ();
            left_click.set_button (Gdk.BUTTON_PRIMARY);
            left_click.pressed.connect ((n_press, gx, gy) => {
                clear_tree_selection ();
                var data = list_item.get_item () as ItemData;
                if (data != null) update_preview (data);
            });
            box.add_controller (left_click);

            list_item.set_child (box);
        });

        factory.bind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var data = list_item.get_item () as ItemData;
            if (data == null) return;

            var box = list_item.get_child () as Gtk.Box;
            if (box == null) return;

            // 存储 ItemData 引用到 box 上, 供 list_drop 的 pick() 定位目标行
            box.set_data<ItemData> ("queue-item", data);

            // 行内子控件顺序: 拖拽手柄(grip) -> 文件图标(icon) -> 文件名(label).
            // 手柄现为首个子控件, 故取图标需跳过它 (get_first_child 返回的是 grip).
            var grip = box.get_first_child () as Gtk.Image;
            var icon = grip != null ? grip.get_next_sibling () as Gtk.Image : box.get_first_child () as Gtk.Image;
            if (icon == null) return;

            var label = icon.get_next_sibling () as Gtk.Label;
            if (label == null) return;

            // 初始渲染
            render_row (list_item, data, label, icon);

            // 监听 position 变化: 上下移动时 ListView 可能复用 ListItem 跟随 item 移动,
            // 而不触发 bind, 仅更新 position; 需监听 position 以重新渲染编号
            ulong pos_handler = list_item.notify["position"].connect (() => {
                var current_data = list_item.get_item () as ItemData;
                if (current_data != null) {
                    render_row (list_item, current_data, label, icon);
                }
            });

            // 监听 content 变化: 编辑确认后 edit_data.content = text 会触发 notify,
            // 实时刷新行内预览 (splice 复用同一对象引用时 ListView 不会重新 bind)
            ulong handler_id = data.notify["content"].connect (() => {
                if (list_item != null && list_item.get_item () != null) {
                    render_row (list_item, data, label, icon);
                }
            });

            // 监听 preprocess_status 变化: 多模态 AI 预处理完成后刷新状态标签
            // 属性变更已在主线程执行 (通过 Idle.add 调度), 此处可直接渲染
            // 注意: GObject 属性名用连字符, 不是下划线
            ulong status_handler_id = data.notify["preprocess-status"].connect (() => {
                if (list_item != null && list_item.get_item () != null) {
                    render_row (list_item, data, label, icon);
                }
                // 防御 + 同步刷新预览: queue_update_depth > 0 时跳过 (避免访问
                // 不稳定模型), 否则若本行是被选中的当前预览项则刷新预览,
                // 避免 VLM 完成后预览区仍显示旧内容. selection/current_preview_item
                // 检查由 Window 通过 refresh_preview_if_active 集中处理.
                if (is_queue_updating ()) return;
                refresh_preview_if_active (data, list_item.get_position ());
            });

            // 监听 from_cache 变化: COMPLETED 状态下显示"已缓存"/"已转换"依赖此属性
            ulong cache_handler_id = data.notify["from-cache"].connect (() => {
                if (list_item != null && list_item.get_item () != null) {
                    render_row (list_item, data, label, icon);
                }
            });

            // 将句柄 ID 与所监视的数据模型指针弱挂载到 ListItem 容器上,
            // 供 unbind 时双重校验安全剥离信号
            list_item.set_data<ulong> ("content_notify_id", handler_id);
            list_item.set_data<ulong> ("status_notify_id", status_handler_id);
            list_item.set_data<ulong> ("cache_notify_id", cache_handler_id);
            list_item.set_data<ulong> ("position_notify_id", pos_handler);
            list_item.set_data<ItemData> ("monitored_data_ptr", data);
        });

        factory.unbind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            ulong handler_id = list_item.get_data<ulong> ("content_notify_id");
            ulong status_handler_id = list_item.get_data<ulong> ("status_notify_id");
            ulong cache_handler_id = list_item.get_data<ulong> ("cache_notify_id");
            ulong pos_handler = list_item.get_data<ulong> ("position_notify_id");
            var data = list_item.get_data<ItemData> ("monitored_data_ptr");

            // 安全双重校验: 确认句柄未失效且数据对象依然存在于内存中, 方能安全剥离信号
            if (handler_id != 0 && data != null && GLib.SignalHandler.is_connected (data, handler_id)) {
                GLib.SignalHandler.disconnect (data, handler_id);
            }
            if (status_handler_id != 0 && data != null && GLib.SignalHandler.is_connected (data, status_handler_id)) {
                GLib.SignalHandler.disconnect (data, status_handler_id);
            }
            if (cache_handler_id != 0 && data != null && GLib.SignalHandler.is_connected (data, cache_handler_id)) {
                GLib.SignalHandler.disconnect (data, cache_handler_id);
            }
            if (pos_handler != 0 && GLib.SignalHandler.is_connected (list_item, pos_handler)) {
                GLib.SignalHandler.disconnect (list_item, pos_handler);
            }

            // 显式清空存储节点引用, 防止生命周期残留导致内存泄露
            list_item.set_data ("content_notify_id", null);
            list_item.set_data ("status_notify_id", null);
            list_item.set_data ("cache_notify_id", null);
            list_item.set_data ("position_notify_id", null);
            list_item.set_data ("monitored_data_ptr", null);

            // 清理 box 上的 ItemData 引用 (bind 时挂载, 供 list_drop pick 使用)
            var unbind_box = list_item.get_child () as Gtk.Box;
            if (unbind_box != null) {
                unbind_box.set_data<ItemData> ("queue-item", null);
            }
        });

        return factory;
    }

    // ─── 默认行渲染实现 ───────────────────────────────────────────────
    // 渲染编排列表单行: 根据 item_type 计算 display_name 和 icon, 写入 label/icon.
    // 作为静态方法提供, Window 通过 RenderRow Hook 直接传入此函数引用即可复用.
    public static void render_row_default (Gtk.ListItem list_item, ItemData data, Gtk.Label label, Gtk.Image icon) {
        string display_name;
        string icon_name;
        if (data.item_type == "file") {
            var file = File.new_for_path (data.file_path);
            display_name = file.get_basename ();
            if (data.is_snippet ()) {
                display_name += " [L%d-L%d]".printf (data.start_line, data.end_line);
            }
            if (data.is_missing) {
                icon_name = "dialog-warning-symbolic";
                display_name = _("%s (missing)").printf (display_name);
            } else {
                // 根据文件类型选择 GTK 原生图标
                if (data.is_image_target ()) {
                    icon_name = "image-x-generic-symbolic";
                } else if (data.is_document_target ()) {
                    icon_name = "x-office-document-symbolic";
                } else if (data.force_absolute) {
                    icon_name = "document-open-symbolic";
                } else {
                    icon_name = "text-x-generic-symbolic";
                }

                if (data.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                    switch (data.preprocess_status) {
                        case PreprocessStatus.PENDING:
                            display_name += _("Pending");
                            break;
                        case PreprocessStatus.CHECKING:
                            // 正在查缓存, 还没真去调 VLM; 复用缓存时只闪这一行
                            display_name += _("[Checking cache...]");
                            break;
                        case PreprocessStatus.PROCESSING:
                            display_name += _("Processing...");
                            break;
                        case PreprocessStatus.COMPLETED:
                            string cache_tag = data.from_cache ? _("Cached") : _("Converted");
                            display_name += " [%s]".printf (cache_tag);
                            break;
                        case PreprocessStatus.FAILED:
                            display_name += _(" [Conversion failed]");
                            break;
                    }
                }
                if (data.force_absolute) {
                    display_name += " [%s]".printf (_("External file"));
                }
            }
        } else {
            var preview = data.content ?? "";
            if (preview.char_count () > 40) {
                int byte_pos = preview.index_of_nth_char (40);
                preview = preview.substring (0, byte_pos) + "…";
            }
            display_name = preview;
            // 自定义文字项: 用标准图标 document-edit-symbolic (编辑/文本草稿语义).
            // 注意: 不能用 "edit-symbolic" —— 该名称不属于 FreeDesktop/Adwaita 标准图标
            // 命名, 在 Adwaita 等主题下会显示"图标未找到"占位符.
            icon_name = "document-edit-symbolic";
        }

        var pos = list_item.get_position ();
        label.set_text ("%d. %s".printf ((int)pos + 1, display_name));
        icon.icon_name = icon_name;
    }
}
