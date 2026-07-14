using Gtk;

/**
 * 面板尺寸 / 最小宽度布局管理器
 *
 * 纯几何计算: 持有 outer / inner / ai 三个 Paned 控件与 ai_sidebar,
 * 负责在窗口缩放、AI 侧边栏显隐时约束各栏分隔条位置并计算窗口最小宽度,
 * 避免面板内容被裁剪. 不持有任何业务状态.
 */
public class PaneLayoutManager : GLib.Object {
    private const int PANED_SEP = 12;

    private AppState app_state;
    private Gtk.Paned outer_paned;
    private Gtk.Paned inner_paned;
    private Gtk.Paned ai_paned;
    private Gtk.Widget ai_sidebar;

    // 阻断 clamp_outer_paned_position 在修改 outer_paned.position 时
    // 触发 notify["position"] 信号导致的递归调用
    private bool _clamping_outer = false;
    // 阻断 clamp_inner_paned_position 在 outer 同步 clamp 时触发递归
    private bool _clamping_inner_from_outer = false;

    private int left_min_width = 0;
    private int center_min_width = 0;
    private int right_min_width = 0;

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

    public void setup () {
        outer_paned.notify["position"].connect (clamp_outer_paned_position);
        outer_paned.notify["width"].connect (clamp_outer_paned_position);
        inner_paned.notify["position"].connect (clamp_inner_paned_position);

        GLib.Idle.add (() => {
            if (app_state.window_closing) return Source.REMOVE;
            measure_pane_minimums ();
            update_min_size ();
            clamp_outer_paned_position ();
            clamp_inner_paned_position ();
            return Source.REMOVE;
        });
    }

    // 根据当前可见面板的最小宽度, 计算并设置 ai_paned 的最小宽度,
    // 防止窗口缩小到导致面板内容被裁剪. (AI 侧边栏显隐后也需重新调用)
    public void update_min_size () {
        int min_w = 0;

        // ai_paned 自身的 margin
        min_w += ai_paned.get_margin_start () + ai_paned.get_margin_end ();

        // AI 边栏 (可见时才计入)
        if (ai_sidebar.get_visible ()) {
            min_w += ai_sidebar.get_margin_start () + ai_sidebar.get_margin_end ();
            min_w += 280; // ai_sidebar 的 width-request
            min_w += PANED_SEP; // ai_paned 分隔条
        }

        // outer_paned margin
        min_w += outer_paned.get_margin_start () + outer_paned.get_margin_end ();

        // 左栏
        var left_child = outer_paned.get_start_child ();
        if (left_child != null) {
            min_w += left_child.get_margin_start () + left_child.get_margin_end ();
            min_w += left_min_width;
            min_w += PANED_SEP; // outer_paned 分隔条
        }

        // inner_paned margin
        min_w += inner_paned.get_margin_start () + inner_paned.get_margin_end ();

        // 中栏
        var center_child = inner_paned.get_start_child ();
        if (center_child != null) {
            min_w += center_child.get_margin_start () + center_child.get_margin_end ();
            min_w += center_min_width;
            min_w += PANED_SEP; // inner_paned 分隔条
        }

        // 右栏
        var right_child = inner_paned.get_end_child ();
        if (right_child != null) {
            min_w += right_child.get_margin_start () + right_child.get_margin_end ();
            min_w += right_min_width;
        }

        ai_paned.set_size_request (min_w, -1);
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

    private void clamp_outer_paned_position () {
        if (_clamping_outer) return;
        _clamping_outer = true;
        var pw = outer_paned.get_width ();
        if (pw <= 0) {
            _clamping_outer = false;
            return;
        }
        var pos = outer_paned.position;
        var cw = pw - outer_paned.get_margin_start () - outer_paned.get_margin_end ();

        // 子项 margin: measure() 返回的 min 不含 margin, 需额外计入
        var left_child = outer_paned.get_start_child ();
        int left_margin = (left_child != null)
            ? left_child.get_margin_start () + left_child.get_margin_end () : 0;

        var center_child = inner_paned.get_start_child ();
        var right_child = inner_paned.get_end_child ();
        int center_margin = (center_child != null)
            ? center_child.get_margin_start () + center_child.get_margin_end () : 0;
        int right_margin = (right_child != null)
            ? right_child.get_margin_start () + right_child.get_margin_end () : 0;
        int inner_margin = inner_paned.get_margin_start () + inner_paned.get_margin_end ();

        var min_pos = left_min_width + left_margin;
        // inner_paned 需要的最小宽度 = 自身 margin + 中栏(含margin) + 分隔条 + 右栏(含margin)
        var inner_needed = inner_margin + center_margin + center_min_width
            + PANED_SEP + right_margin + right_min_width;
        var max_pos = int.max (min_pos, cw - PANED_SEP - inner_needed);
        if (pos < min_pos) {
            outer_paned.position = min_pos;
        } else if (pos > max_pos) {
            outer_paned.position = max_pos;
        }

        // 同步 clamp inner_paned
        var inner_width = cw - PANED_SEP - outer_paned.position;
        var icw = inner_width - inner_paned.get_margin_start () - inner_paned.get_margin_end ();
        var ipos = inner_paned.position;
        var imin = center_min_width + center_margin;
        var imax = int.max (imin, icw - PANED_SEP - right_min_width - right_margin);
        _clamping_inner_from_outer = true;
        if (ipos < imin) {
            inner_paned.position = imin;
        } else if (ipos > imax) {
            inner_paned.position = imax;
        }
        _clamping_inner_from_outer = false;
        _clamping_outer = false;
    }

    private void clamp_inner_paned_position () {
        if (_clamping_inner_from_outer) return;
        var pw = inner_paned.get_width ();
        if (pw <= 0) return;
        var pos = inner_paned.position;
        var cw = pw - inner_paned.get_margin_start () - inner_paned.get_margin_end ();

        var center_child = inner_paned.get_start_child ();
        var right_child = inner_paned.get_end_child ();
        int center_margin = (center_child != null)
            ? center_child.get_margin_start () + center_child.get_margin_end () : 0;
        int right_margin = (right_child != null)
            ? right_child.get_margin_start () + right_child.get_margin_end () : 0;

        var min_pos = center_min_width + center_margin;
        var max_pos = int.max (min_pos, cw - PANED_SEP - right_min_width - right_margin);
        if (pos < min_pos) {
            inner_paned.position = min_pos;
        } else if (pos > max_pos) {
            inner_paned.position = max_pos;
        }
    }
}
