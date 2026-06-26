public class GitCommit : GLib.Object {
    public string hash { get; set; }
    public string short_hash { get; set; }
    public string author { get; set; }
    public string date { get; set; }
    public string message { get; set; }

    public GitCommit (string hash, string author, string date, string message) {
        this.hash = hash;
        this.short_hash = hash.length > 7 ? hash.substring (0, 7) : hash;
        this.author = author;
        this.date = date;
        this.message = message;
    }
}
