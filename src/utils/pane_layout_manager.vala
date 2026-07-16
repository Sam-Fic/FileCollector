using Gtk;

/**
 * 面板尺寸 / 最小宽度布局管理器
 *
 * 策略: 所有 Paned 在 construct 中程序化设置 shrink 属性,
 * 不依赖 BLP 编译. shrink-start-child: true 允许 start child 缩小,
 * shrink-end-child: false 保证 end child 不被裁剪.
 * 不连接任何 notify 信号, 完全依赖 Paned 自身的分配逻辑.
 */
public class PaneLayoutManager : GLib.Object {
    private const int PANED_SEP = 12;

    private AppState app_state;
    private Gtk.Paned outer_paned;
    private Gtk.Paned inner_paned;
    private Gtk.Paned ai_paned;
    private Gtk.Widget ai_sidebar;
    private Adw.ApplicationWindow? window = null;

    private int left_min_width = 200;
    private int center_min_width = 400;
    private int right_min_width = 200;

    public PaneLayoutManager (
        AppState app_state,
        Gtk.Paned outer_paned,
        Gtk.Paned inner_paned,
        Gtk.Paned ai_paned,
        Gtk.Widget ai_sidebar
    ) {
        this.app_state = app_state;
        this.outer_paned = outer_paned;
        this.inner_paned = inner_paned;
        this.ai_paned = ai_paned;
        this.ai_sidebar = ai_sidebar;
    }

    public void set_window (Adw.ApplicationWindow win) {
        this.window = win;
    }

    public void setup () {
        // 程序化强制设置, 不依赖 BLP 编译
        // start child 可缩小 → 窗口窄时左栏/中栏先缩
        // end child 不可缩小 → 预览栏永不被裁剪
        outer_paned.set_shrink_start_child (true);
        outer_paned.set_shrink_end_child (false);
        inner_paned.set_shrink_start_child (false);
        inner_paned.set_shrink_end_child (false);

        GLib.Idle.add (() => {
            if (app_state.window_closing) return Source.REMOVE;
            measure_pane_minimums ();
            update_min_size ();
            return Source.REMOVE;
        });
    }

    public void update_min_size () {
        int min_w = 0;

        min_w += ai_paned.get_margin_start () + ai_paned.get_margin_end ();

        if (ai_sidebar.get_visible ()) {
            min_w += ai_sidebar.get_margin_start () + ai_sidebar.get_margin_end ();
            min_w += 280;
            min_w += PANED_SEP;
        }

        min_w += outer_paned.get_margin_start () + outer_paned.get_margin_end ();

        var left_child = outer_paned.get_start_child ();
        if (left_child != null) {
            min_w += left_child.get_margin_start () + left_child.get_margin_end ();
            min_w += left_min_width;
            min_w += PANED_SEP;
        }

        min_w += inner_paned.get_margin_start () + inner_paned.get_margin_end ();

        var center_child = inner_paned.get_start_child ();
        if (center_child != null) {
            min_w += center_child.get_margin_start () + center_child.get_margin_end ();
            min_w += center_min_width;
            min_w += PANED_SEP;
        }

        var right_child = inner_paned.get_end_child ();
        if (right_child != null) {
            min_w += right_child.get_margin_start () + right_child.get_margin_end ();
            min_w += right_min_width;
        }

        ai_paned.set_size_request (min_w, -1);

        if (window != null) {
            window.set_size_request (min_w, -1);
        }
    }

    private void measure_pane_minimums () {
        int min, nat;

        var left_child = outer_paned.get_start_child ();
        if (left_child != null) {
            left_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            left_min_width = int.max (min, 200);
        }

        var center_child = inner_paned.get_start_child ();
        if (center_child != null) {
            center_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            center_min_width = int.max (min, 400);
        }

        var right_child = inner_paned.get_end_child ();
        if (right_child != null) {
            right_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            right_min_width = int.max (min, 200);
        }
    }
}
