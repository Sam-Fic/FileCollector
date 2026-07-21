// 目录树 (dir_column_view) 的 ColumnView + SignalListItemFactory 构建器
//
// 从 window.vala setup_tree_view 中提取的 factory.setup/bind/unbind 回调
// 和数据模型构建逻辑 (root_store → TreeListModel → FilterListModel → SingleSelection).
//
// 设计要点 (与 QueueListFactory 相同的 Hooks 委托模式):
//   - factory 不持有 Window 引用, 不接触 [GtkChild] widget (dir_scrolled),
//     也不访问 Window 私有字段 (queue_selection/search_text 等).
//   - 通过 Hooks 委托回 Window: filter_tree_func / preview_tree_item_at /
//     on_tree_selection_changed / on_column_view_activated / show_tree_context_menu /
//     on_check_toggled / highlight_tree_label / load_directory_children_lazy /
//     queue_selection.unselect_all (用 UnselectAllQueue Hook).
//   - tree_selection 在 factory 内部创建并暴露在 Result 中, factory 内部 click
//     回调直接用本地变量赋值; Window 通过 Result.tree_selection 在外部访问.
//   - 返回 Result 而非单个 ColumnView: Window 后续需要 root_store / filter_model /
//     tree_filter / tree_selection 等引用做搜索过滤、selection 同步等操作.

public class FileTreeFactory : GLib.Object {

    // ─── Hooks 委托 ────────────────────────────────────────────────────

    public delegate bool FilterFunc (GLib.Object item);
    public delegate void SelectionChanged (uint position, uint n_items);
    public delegate void Activated (uint position);
    public delegate void PreviewAt (uint position);
    public delegate void UnselectAllQueue ();
    public delegate void ShowTreeContextMenu (Gtk.Widget anchor, DirectoryItem item, int gx, int gy);
    public delegate void CheckToggled (Gtk.CheckButton check);
    public delegate void HighlightLabel (Gtk.Label label, string name);
    public delegate void LoadDirChildrenLazy (DirectoryItem item);

    // ─── Result: factory 创建的所有模型和视图对象 ─────────────────────

    public class Result : GLib.Object {
        public Gtk.ColumnView view;
        public GLib.ListStore root_store;
        public Gtk.TreeListModel tree_list_model;
        public Gtk.FilterListModel filter_model;
        public Gtk.CustomFilter tree_filter;
        public Gtk.SingleSelection tree_selection;
    }

    // ─── 入口 ─────────────────────────────────────────────────────────

    public static Result create (
        FilterFunc filter_func,
        SelectionChanged selection_changed,
        Activated activated,
        PreviewAt preview_at,
        UnselectAllQueue unselect_all_queue,
        ShowTreeContextMenu show_tree_context_menu,
        CheckToggled check_toggled,
        HighlightLabel highlight_label,
        LoadDirChildrenLazy load_dir_children_lazy
    ) {
        var root_store = new GLib.ListStore (typeof (DirectoryItem));

        var tree_list_model = new Gtk.TreeListModel (
            root_store,
            false,
            false,
            (item) => ((DirectoryItem)item).children
        );

        var tree_filter = new Gtk.CustomFilter (filter_func);
        var filter_model = new Gtk.FilterListModel (tree_list_model, tree_filter);

        var tree_selection = new Gtk.SingleSelection (filter_model);
        tree_selection.set_autoselect (false);

        var dir_column_view = new Gtk.ColumnView (tree_selection);
        dir_column_view.add_css_class ("file-tree");

        var expander_factory = new Gtk.SignalListItemFactory ();
        expander_factory.setup.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;

            var expander = new Gtk.TreeExpander ();
            expander.set_indent_for_icon (true);

            var check = new Gtk.CheckButton ();
            check.add_css_class ("tree-check");
            check.valign = Gtk.Align.CENTER;

            var label = new Gtk.Label ("");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0;
            label.hexpand = true;
            label.valign = Gtk.Align.CENTER;

            var click = new Gtk.GestureClick ();
            click.pressed.connect (() => {
                var row = list_item.get_item () as Gtk.TreeListRow;
                if (row == null) return;
                var item = row.get_item () as DirectoryItem;
                if (item == null || item.is_dir) return;

                var pos = list_item.get_position ();
                tree_selection.selected = pos;
                // preview_tree_item_at 已包含缓存检查, 不要再用
                // 无缓存的 temp_item 调用 update_preview, 否则会覆盖正确预览
                preview_at (pos);
                unselect_all_queue ();
            });
            label.add_controller (click);

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.margin_top = 0;
            box.margin_bottom = 0;
            box.margin_start = 2;
            box.margin_end = 2;
            box.append (check);
            box.append (label);

            var right_click_tree = new Gtk.GestureClick ();
            right_click_tree.set_button (Gdk.BUTTON_SECONDARY);
            right_click_tree.pressed.connect ((n_press, gx, gy) => {
                var li = obj as Gtk.ListItem;
                if (li == null) return;
                var row = li.get_item () as Gtk.TreeListRow;
                if (row == null) return;
                var dir_item = row.get_item () as DirectoryItem;
                if (dir_item == null) return;
                tree_selection.selected = li.get_position ();
                // 传 box 而非 li.get_child() (expander), 保证 popover parent 与
                // 手势坐标的参考系一致, 否则菜单会偏移到 expander 左上角附近
                show_tree_context_menu (box, dir_item, (int) gx, (int) gy);
            });
            box.add_controller (right_click_tree);

            expander.set_child (box);
            list_item.set_child (expander);
        });

        expander_factory.bind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var row = list_item.get_item () as Gtk.TreeListRow;
            if (row == null) return;

            var item = row.get_item () as DirectoryItem;
            if (item == null) return;

            var expander = list_item.get_child () as Gtk.TreeExpander;
            if (expander == null) return;

            var box = expander.get_child () as Gtk.Box;
            if (box == null) return;

            var check = box.get_first_child () as Gtk.CheckButton;
            if (check == null) return;

            var label = check.get_next_sibling () as Gtk.Label;
            if (label == null) return;

            expander.set_list_row (row);
            expander.set_hide_expander (!item.is_dir);

            check.active = item.checked;
            check.inconsistent = item.inconsistent;

            check.set_data<DirectoryItem> ("item", item);
            // notify 信号处理器签名是 (GLib.Object, GLib.ParamSpec), 这里包装
            // 成 CheckToggled (Gtk.CheckButton) 让 Window 实现更简洁.
            ulong handler_id = check.notify["active"].connect ((notify_obj, pspec) => {
                var cb = notify_obj as Gtk.CheckButton;
                if (cb != null) check_toggled (cb);
            });
            check.set_data<ulong?> ("handler_id", handler_id);

            ulong state_handler_id = item.state_changed.connect (() => {
                var hid = check.get_data<ulong?> ("handler_id");
                if (hid != null) {
                    SignalHandler.block (check, hid);
                }
                check.active = item.checked;
                check.inconsistent = item.inconsistent;
                if (hid != null) {
                    SignalHandler.unblock (check, hid);
                }
            });
            check.set_data<ulong?> ("state_handler_id", state_handler_id);

            highlight_label (label, item.name);

            if (item.is_dir) {
                ulong expanded_handler_id = row.notify["expanded"].connect (() => {
                    if (row.get_expanded () && item.children.get_n_items () == 0 && !item.children_loading) {
                        load_dir_children_lazy (item);
                    }
                });
                row.set_data<ulong?> ("expanded-handler", expanded_handler_id);
            }
        });

        expander_factory.unbind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var expander = list_item.get_child () as Gtk.TreeExpander;
            if (expander == null) return;

            var box = expander.get_child () as Gtk.Box;
            if (box == null) return;

            var check = box.get_first_child () as Gtk.CheckButton;
            if (check == null) return;

            var handler_id = check.get_data<ulong?> ("handler_id");
            if (handler_id != null) {
                GLib.SignalHandler.disconnect (check, handler_id);
            }

            var state_handler_id = check.get_data<ulong?> ("state_handler_id");
            var item = check.get_data<DirectoryItem> ("item");
            if (state_handler_id != null && item != null) {
                GLib.SignalHandler.disconnect (item, state_handler_id);
            }

            var row = list_item.get_item () as Gtk.TreeListRow;
            if (row != null) {
                var expanded_handler_id = row.get_data<ulong?> ("expanded-handler");
                if (expanded_handler_id != null) {
                    GLib.SignalHandler.disconnect (row, expanded_handler_id);
                }
            }

            expander.set_list_row (null);
        });

        var column = new Gtk.ColumnViewColumn (null, expander_factory);
        column.set_expand (true);
        dir_column_view.append_column (column);

        dir_column_view.show_column_separators = false;
        dir_column_view.show_row_separators = false;

        // 隐藏 ColumnView 默认 header (单一列无需标题行). 用 Idle 而非直接访问:
        // ColumnView 在 append_column 后才会创建 header 子节点, 同步访问可能拿到 null.
        GLib.Idle.add (() => {
            var child = dir_column_view.get_first_child ();
            if (child != null) {
                child.visible = false;
            }
            return Source.REMOVE;
        });

        // 注意: 不能直接 connect 传入的实例方法 delegate. SelectionChanged /
        // Activated 是无 target 的 delegate 类型, 若把 window 实例方法直接注册为
        // GTK 信号处理器, Vala 生成的 thunk 会把 self 当作第三个隐藏参数, 而 GTK
        // 发射信号时只传 (position[, n_items]), 导致 self 取到栈垃圾 (0x1) 且
        // position 错乱, 进而解引用失效对象崩溃. 用 lambda 包装后编译为无 target
        // 静态函数, 签名与 GTK 信号精确匹配, self 通过闭包正确持有.
        tree_selection.selection_changed.connect ((pos, n) => selection_changed (pos, n));
        dir_column_view.activate.connect ((pos) => activated (pos));

        var result = new Result ();
        result.view = dir_column_view;
        result.root_store = root_store;
        result.tree_list_model = tree_list_model;
        result.filter_model = filter_model;
        result.tree_filter = tree_filter;
        result.tree_selection = tree_selection;
        return result;
    }
}
