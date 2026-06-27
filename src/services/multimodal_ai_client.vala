using GLib;
using Json;
using Soup;

public class MultimodalAIClient : GLib.Object {
    public string base_url { get; construct; }
    public string api_key { get; construct; }
    public string model { get; construct; }
    public string prompt { get; construct; }
    private Soup.Session session;

    public MultimodalAIClient (string url, string key, string mdl, string prmt, double timeout) {
        GLib.Object (base_url: url, api_key: key, model: mdl, prompt: prmt);
        session = new Soup.Session ();
        session.timeout = (uint) timeout;
    }

    public string process_images (string[] base64_images, string[]? mime_types = null) throws Error {
        var payload = new Json.Object ();
        payload.set_string_member ("model", model);

        var content_arr = new Json.Array ();
        content_arr.add_element (AI.SchemaHelper.obj_to_node (
            build_text_part (prompt)
        ));

        for (int i = 0; i < base64_images.length; i++) {
            string mime = (mime_types != null && i < mime_types.length)
                ? mime_types[i] : "image/png";
            content_arr.add_element (AI.SchemaHelper.obj_to_node (
                build_image_part (base64_images[i], mime)
            ));
        }

        var msg_obj = new Json.Object ();
        msg_obj.set_string_member ("role", "user");
        msg_obj.set_member ("content", AI.SchemaHelper.arr_to_node (content_arr));

        var msgs_arr = new Json.Array ();
        msgs_arr.add_element (AI.SchemaHelper.obj_to_node (msg_obj));
        payload.set_member ("messages", AI.SchemaHelper.arr_to_node (msgs_arr));

        var gen = new Json.Generator ();
        gen.set_root (AI.SchemaHelper.obj_to_node (payload));
        size_t body_len = 0;
        string body = gen.to_data (out body_len);

        string url = base_url.has_suffix ("/") ? base_url + "chat/completions" : base_url + "/chat/completions";
        var msg = new Soup.Message ("POST", url);
        uint8[] body_buf = new uint8[body_len];
        GLib.Memory.copy (body_buf, body, body_len);
        msg.set_request_body_from_bytes ("application/json", new Bytes (body_buf));
        msg.request_headers.append ("Authorization", "Bearer " + api_key);

        var resp = session.send_and_read (msg, null);
        if (msg.status_code >= 400) {
            string detail = "";
            if (resp != null && resp.length > 0) {
                uint8[] raw = resp.get_data ();
                int safe_len = (int) int64.min (resp.length, 2048);
                detail = ((string) raw).substring (0, safe_len);
            }
            throw new IOError.FAILED ("HTTP %u: %s".printf (msg.status_code, detail));
        }

        var parser = new Json.Parser ();
        parser.load_from_data ((string) resp.get_data ());
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
            throw new IOError.FAILED ("Invalid response format");

        var root_obj = root.get_object ();
        if (root_obj == null) throw new IOError.FAILED ("Response root is not an object");
        var choices = root_obj.get_array_member ("choices");
        if (choices == null || choices.get_length () == 0) throw new IOError.FAILED ("Empty choices array");
        var resp_msg = choices.get_object_element (0).get_object_member ("message");
        if (resp_msg == null) throw new IOError.FAILED ("Missing message object");
        string? content = resp_msg.get_string_member ("content");
        if (content == null) throw new IOError.FAILED ("Missing content in response");

        // 去掉 API 响应开头/结尾的多余空行
        content = content.strip ();
        return content;
    }

    private static Json.Object build_text_part (string text) {
        var o = new Json.Object ();
        o.set_string_member ("type", "text");
        o.set_string_member ("text", text);
        return o;
    }

    private static Json.Object build_image_part (string base64_data, string mime) {
        var img_obj = new Json.Object ();
        img_obj.set_string_member ("type", "image_url");
        var url_obj = new Json.Object ();
        url_obj.set_string_member ("url", "data:" + mime + ";base64," + base64_data);
        img_obj.set_member ("image_url", AI.SchemaHelper.obj_to_node (url_obj));
        return img_obj;
    }
}
