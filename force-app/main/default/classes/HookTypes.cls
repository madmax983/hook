/**
 * @description Makes an instance of a configured class.
 */
public inherited sharing class HookTypes {
  /**
   * @description Makes an instance of a class by name.
   * @param className The class name, with a namespace when necessary.
   * @param kind The interface name, for the error text.
   * @return The instance.
   * @throws HookException When the class is not found or cannot be made.
   */
  public static Object make(String className, String kind) {
    Type t = String.isBlank(className) ? null : Type.forName(className.trim());
    if (t == null) {
      throw new HookException(
        'The ' + kind + ' class "' + className + '" is not found.'
      );
    }
    try {
      return t.newInstance();
    } catch (Exception e) {
      throw new HookException(
        'The ' +
          kind +
          ' class "' +
          className +
          '" cannot be made: ' +
          e.getMessage()
      );
    }
  }

  /**
   * @description Gives the error for an instance that is not of the interface.
   * @param className The class name.
   * @param kind The interface name.
   * @return The error.
   */
  public static HookException wrongType(String className, String kind) {
    return new HookException(
      'The class "' + className + '" does not implement ' + kind + '.'
    );
  }
}
