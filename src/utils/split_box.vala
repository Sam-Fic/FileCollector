using Gtk;

/**
 * 自定义水平 Box: 中栏/分隔条/右栏.
 * 重写 size_allocate, 按固定比例分配空间, 不改变子控件 natural size.
 */
public class SplitBox : Gtk.Box {
    private int _right_width = 200;
    private const int SEP_WIDTH = 12;
    private const int CENTER_MIN = 400;

    construct {
        orientation = Gtk.Orientation.HORIZONTAL;
    }

    public void set_right_width (int w) {
        _right_width = int.max (200, w);
        queue_resize ();
    }

    public int get_right_width () {
        return _right_width;
    }

    public int get_center_width () {
        var c = get_first_child ();
        return c != null ? c.get_allocated_width () : 0;
    }

    private void alloc_at (Gtk.Widget child, int x, int w) {
        Gtk.Allocation a = {};
        a.x = x;
        a.y = 0;
        a.width = w;
        a.height = get_allocated_height ();
        child.allocate_size (a, -1);
    }

    public override void size_allocate (int width, int height, int baseline) {
        var center = get_first_child ();
        var sep = center != null ? center.get_next_sibling () : null;
        var right = sep != null ? sep.get_next_sibling () : null;

        if (center == null || sep == null || right == null) {
            base.size_allocate (width, height, baseline);
            return;
        }

        int right_w = int.max (200, int.min (_right_width, width - CENTER_MIN - SEP_WIDTH));
        int sep_w = SEP_WIDTH;
        int center_w = width - sep_w - right_w;
        if (center_w < CENTER_MIN) {
            center_w = CENTER_MIN;
            right_w = int.max (200, width - center_w - sep_w);
        }

        alloc_at (center, 0, center_w);
        alloc_at (sep, center_w, sep_w);
        alloc_at (right, center_w + sep_w, right_w);
    }

    public override void measure (Gtk.Orientation orientation, int for_size,
                                   out int minimum, out int natural,
                                   out int minimum_baseline, out int natural_baseline) {
        minimum_baseline = -1;
        natural_baseline = -1;

        if (orientation == Gtk.Orientation.HORIZONTAL) {
            minimum = CENTER_MIN + 12 + 200;
            natural = minimum;
        } else {
            int min_h = 0, nat_h = 0;
            for (var child = get_first_child (); child != null; child = child.get_next_sibling ()) {
                int cm, cn, cb, nb;
                child.measure (orientation, -1, out cm, out cn, out cb, out nb);
                min_h = int.max (min_h, cm);
                nat_h = int.max (nat_h, cn);
            }
            minimum = min_h;
            natural = nat_h;
        }
    }
}
