import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:maid/providers/character.dart';
import 'package:maid/providers/model.dart';
import 'package:maid/static/logger.dart';
import 'package:maid/types/chat_node.dart';
import 'package:maid/static/generation_manager.dart';
import 'package:maid/types/generation_context.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Session extends ChangeNotifier {
  ChatNode _root = ChatNode(key: UniqueKey());
  ChatNode? tail;

  void init() async {
    Logger.log("Session Initialised");

    final prefs = await SharedPreferences.getInstance();

    Map<String, dynamic> lastSession = json.decode(prefs.getString("last_session") ?? "{}") ?? {};

    if (lastSession.isNotEmpty) {
      fromMap(lastSession);
    } else {
      newSession();
    }
  }

  Session() {
    newSession();
  }

  Session.fromMap(Map<String, dynamic> inputJson) {
    fromMap(inputJson);
  }

  void _save() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString("last_session", json.encode(toMap()));
    });
  }

  void newSession() {
    final key = UniqueKey();
    _root = ChatNode(key: key);
    _root.message = "Session ${key.toString()}";
    tail = null;
    notifyListeners();
  }

  void fromMap(Map<String, dynamic> inputJson) {
    _root = ChatNode.fromMap(inputJson);
    tail = _root.findTail();
    notifyListeners();
  }

  Map<String, dynamic> toMap() {
    return _root.toMap();
  }

  String get(Key key) {
    return _root.find(key)?.message ?? "";
  }

  void setRootMessage(String message) {
    _root.message = message;
    notifyListeners();
  }

  String get rootMessage => _root.message;
  Key get key => _root.key;

  Future<void> add(Key key, {String message = "", bool userGenerated = false}) async {
    final node =
        ChatNode(key: key, message: message, userGenerated: userGenerated);

    var found = _root.find(key);
    if (found != null) {
      found.message = message;
    } else {
      tail ??= _root.findTail();

      if (tail!.userGenerated == userGenerated) {
        stream(message);
        finalise();
      } else {
        tail!.children.add(node);
        tail!.currentChild = key;
        tail = tail!.findTail();
      }
    }

    notifyListeners();
  }

  void remove(Key key) {
    var parent = _root.getParent(key);
    if (parent != null) {
      parent.children.removeWhere((element) => element.key == key);
      tail = _root.findTail();
    }
    GenerationManager.cleanup();
    notifyListeners();
  }

  void stream(String message) async {
    tail ??= _root.findTail();
    if (!GenerationManager.busy && !(tail!.userGenerated)) {
      finalise();
    } else {
      tail!.messageController.add(message);
    }
  }

  void regenerate(Key key, BuildContext context) {
    var parent = _root.getParent(key);
    if (parent == null) {
      return;
    } else {
      branch(key, false);
      GenerationManager.busy = true;
      GenerationManager.prompt(
          parent.message,
          GenerationContext(
              model: context.read<Model>(),
              character: context.read<Character>(),
              session: context.read<Session>()),
          context.read<Session>().stream);
    }
  }

  void branch(Key key, bool userGenerated) {
    var parent = _root.getParent(key);
    if (parent != null) {
      parent.currentChild = null;
      tail = _root.findTail();
    }
    add(UniqueKey(), userGenerated: userGenerated);
    GenerationManager.cleanup();
    notifyListeners();
  }

  void finalise() {
    tail ??= _root.findTail();
    tail!.finaliseController.add(0);

    _save();
    notifyListeners();
  }

  void next(Key key) {
    var parent = _root.getParent(key);
    if (parent != null) {
      if (parent.currentChild == null) {
        parent.currentChild = key;
      } else {
        var currentChildIndex = parent.children
            .indexWhere((element) => element.key == parent.currentChild);
        if (currentChildIndex < parent.children.length - 1) {
          parent.currentChild = parent.children[currentChildIndex + 1].key;
          tail = _root.findTail();
        }
      }
    }

    GenerationManager.cleanup();
    notifyListeners();
  }

  void last(Key key) {
    var parent = _root.getParent(key);
    if (parent != null) {
      if (parent.currentChild == null) {
        parent.currentChild = key;
      } else {
        var currentChildIndex = parent.children
            .indexWhere((element) => element.key == parent.currentChild);
        if (currentChildIndex > 0) {
          parent.currentChild = parent.children[currentChildIndex - 1].key;
          tail = _root.findTail();
        }
      }
    }

    GenerationManager.cleanup();
    notifyListeners();
  }

  int siblingCount(Key key) {
    var parent = _root.getParent(key);
    if (parent != null) {
      return parent.children.length;
    } else {
      return 0;
    }
  }

  int index(Key key) {
    var parent = _root.getParent(key);
    if (parent != null) {
      return parent.children.indexWhere((element) => element.key == key);
    } else {
      return 0;
    }
  }

  Map<Key, bool> history() {
    final Map<Key, bool> history = {};
    var current = _root;

    while (current.currentChild != null) {
      current = current.find(current.currentChild!)!;
      history[current.key] = current.userGenerated;
    }

    return history;
  }

  List<Map<String, dynamic>> getMessages() {
    final List<Map<String, dynamic>> messages = [];
    var current = _root;

    while (current.currentChild != null) {
      current = current.find(current.currentChild!)!;
      String role;
      if (current.userGenerated) {
        role = "user";
      } else {
        role = "assistant";
      }
      messages.add({
        "role": role,
        "content": current.message
      });
    }

    //remove last message if it is empty
    if (messages.isNotEmpty && messages.last.isEmpty) {
      messages.remove(messages.last);
    }

    if (messages.isNotEmpty) {
      messages.remove(messages.last); //remove last message
    }

    return messages;
  }

  StreamController<String> getMessageStream(Key key) {
    return _root.find(key)?.messageController ??
        StreamController<String>.broadcast();
  }

  StreamController<int> getFinaliseStream(Key key) {
    return _root.find(key)?.finaliseController ??
        StreamController<int>.broadcast();
  }
}
