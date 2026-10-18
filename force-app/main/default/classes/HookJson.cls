/**
 * @description Small JSON helpers.
 */
public inherited sharing class HookJson {
  /**
   * @description Parses JSON.
   * @param text The JSON text.
   * @return The value, or null when the text is blank or not JSON.
   */
  public static Object parse(String text) {
    if (String.isBlank(text)) {
      return null;
    }
    try {
      return JSON.deserializeUntyped(text);
    } catch (JSONException e) {
      return null;
    }
  }

  /**
   * @description Reads a value at a dot path. A number segment is a list index.
   * @param root The parsed JSON.
   * @param path The path, for example data.items.0.id.
   * @return The value, or null when the path does not exist.
   */
  public static Object valueAt(Object root, String path) {
    if (String.isBlank(path)) {
      return null;
    }
    Object node = root;
    for (String segment : path.split('\\.')) {
      if (node instanceof Map<String, Object>) {
        node = ((Map<String, Object>) node).get(segment);
      } else if (node instanceof List<Object> && segment.isNumeric()) {
        List<Object> items = (List<Object>) node;
        Integer index = Integer.valueOf(segment);
        node = index < items.size() ? items[index] : null;
      } else {
        return null;
      }
    }
    return node;
  }

  /**
   * @description Reads a text value at a dot path from JSON text.
   * @param text The JSON text.
   * @param path The path.
   * @return The value as text, or null.
   */
  public static String textAt(String text, String path) {
    Object value = valueAt(parse(text), path);
    return value == null ? null : String.valueOf(value);
  }
}
