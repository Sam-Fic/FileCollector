public class PromptTemplate : GLib.Object {
    public string id { get; set; }
    public string name { get; set; }
    public string description { get; set; }
    public string header_text { get; set; }
    public string footer_text { get; set; }
    public string ai_prompt { get; set; }

    public PromptTemplate (string id, string name, string desc, string header, string footer, string prompt) {
        this.id = id;
        this.name = name;
        this.description = desc;
        this.header_text = header;
        this.footer_text = footer;
        this.ai_prompt = prompt;
    }
}
