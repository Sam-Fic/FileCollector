public class UndoState : GLib.Object {
    public GenericArray<ItemData> items { get; private set; }
    public HashTable<string, bool> checked_paths { get; private set; }
    public bool use_absolute { get; private set; }
    public bool show_header { get; private set; }

    public UndoState (
        GenericArray<ItemData> src_items,
        HashTable<string, bool> src_checked_paths,
        bool src_use_absolute,
        bool src_show_header
    ) {
        items = new GenericArray<ItemData> ();
        for (int i = 0; i < src_items.length; i++) {
            var it = src_items.get (i);
            items.add (new ItemData (it.item_type, it.file_path, it.content, it.force_absolute));
        }
        checked_paths = new HashTable<string, bool> (str_hash, str_equal);
        foreach (var key in src_checked_paths.get_keys ()) {
            checked_paths.insert (key, true);
        }
        use_absolute = src_use_absolute;
        show_header = src_show_header;
    }
}

public class UndoManager : GLib.Object {
    public bool can_undo { get { return undo_stack.length > 0; } }
    public bool can_redo { get { return redo_stack.length > 0; } }

    private GenericArray<UndoState> undo_stack;
    private GenericArray<UndoState> redo_stack;
    private bool in_progress = false;

    public signal void state_changed ();

    public UndoManager () {
        undo_stack = new GenericArray<UndoState> ();
        redo_stack = new GenericArray<UndoState> ();
    }

    public void push (UndoState state) {
        if (in_progress) return;
        undo_stack.add (state);
        redo_stack.remove_range (0, redo_stack.length);
        state_changed ();
    }

    public UndoState? undo (UndoState current) {
        if (undo_stack.length == 0) return null;
        redo_stack.add (current);
        var state = undo_stack.get ((int) undo_stack.length - 1);
        undo_stack.remove_index ((int) undo_stack.length - 1);
        in_progress = true;
        state_changed ();
        in_progress = false;
        return state;
    }

    public UndoState? redo (UndoState current) {
        if (redo_stack.length == 0) return null;
        undo_stack.add (current);
        var state = redo_stack.get ((int) redo_stack.length - 1);
        redo_stack.remove_index ((int) redo_stack.length - 1);
        in_progress = true;
        state_changed ();
        in_progress = false;
        return state;
    }

    public void clear () {
        undo_stack.remove_range (0, undo_stack.length);
        redo_stack.remove_range (0, redo_stack.length);
        state_changed ();
    }
}
