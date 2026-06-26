public class SearchResult : GLib.Object {
    public string file_path { get; set; }
    public string rel_path { get; set; }
    public int line_number { get; set; }
    public string line_content { get; set; }

    public SearchResult (string abs, string rel, int line, string content) {
        this.file_path = abs;
        this.rel_path = rel;
        this.line_number = line;
        this.line_content = content;
    }
}
