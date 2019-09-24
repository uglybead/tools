#!/usr/bin/env python3

import sys
import os
import re
import json
import subprocess
import urllib

from django.core.validators import URLValidator
from django.core.exceptions import ValidationError

from PyQt5.QtWidgets import (QApplication, QLabel, QPushButton,
                             QVBoxLayout, QWidget, QTextEdit,
		             QGridLayout, QMenu, QAction, QInputDialog,
			     QLineEdit)

def is_url(uri):
  try:
    URLValidator()(uri)
    return True
  except:
    return False


class ConfigController(object):

  def __init__(self, filename):
    self._filename = filename
    # Stored with most-recent last
    self._prefixes = []
    self._known_prefixes = set(self._prefixes)
    self._filename = filename
    self._try_load()

  def add_prefix(self, prefix):
    if prefix in self._known_prefixes:
      return
    self._prefixes.append(prefix)
    self._known_prefixes.add(prefix)
    self._save()

  def to_front(self, prefix):
    if prefix not in self._known_prefixes:
      return
    self._prefixes.remove(prefix)
    self._prefixes.append(prefix)
    print("Promoting prefix %s" % prefix, "New ordering is [%s]" % self._prefixes)

  def get_prefix(self, index):
    if index >= len(self._prefixes):
      return None
    return self._prefixes[len(self._prefixes) - 1 - index]

  def _try_load(self):
    filename = self._filename
    if not os.path.exists(filename):
      return
    try:
      with open(filename) as f:
        dt = json.load(f)
        if self._looks_valid(dt):
          self._prefixes = dt
          self._known_prefixes = set(dt)
    except Exception as e:
      print("Unable to open prefix file?\n\n%s" % e)

  def _looks_valid(self, parsed_data):
    return ((type(parsed_data) is list) and
	    all(map(lambda x: type(x) is str, parsed_data)))

  def _save(self):
    with open(self._filename, mode='w') as f:
      json.dump(self._prefixes, f)

  def prefix_count(self):
    return len(self._prefixes)


def row_column(index, per_row):
  column, row = index % per_row, index // per_row
  return row, column


class PrefixChooser(QWidget):

  def __init__(self, controller, button_count=7, buttons_per_row=4):
    super(PrefixChooser, self).__init__()
    self._controller = controller
    self._button_count = button_count
    self._buttons_per_row = buttons_per_row
    self.refresh()
    self._selected_prefix = None

  def get_selected(self):
    return self._selected_prefix

  def refresh(self):
    self._buttons = []
    self._other_menu = None
    layout = QGridLayout()
    for i in range(self._button_count):
      row, column = row_column(i, self._buttons_per_row)
      text = self._controller.get_prefix(i)
      self._buttons.append(self._make_button(text))
      layout.addWidget(self._buttons[i], row, column, 1, 1)

    obutton_row, obutton_column = row_column(self._button_count,
					     self._buttons_per_row)

    layout.addWidget(self._make_other_button(),
	             obutton_row, obutton_column, 1, 1)
    if self.layout():
      QWidget().setLayout(self.layout())
    self.setLayout(layout)

  def _make_button(self, text):
    button = QPushButton(text)
    button.setCheckable(True)

    def on_click():
      print("Clicked %s" % text)
      for other in self._buttons:
        other.setChecked(False)

      button.setChecked(True)
      self._selected_prefix = text

    button.clicked.connect(on_click)
    return button

  def _make_other_button(self):
    button = QPushButton("Others")
    button.setMenu(OtherPrefixMenu(self._controller, self._button_count, self))
    return button

  def select_first(self):
    self._buttons[0].click()
    print("Newly selected: %s" % self._selected_prefix)


class OtherPrefixMenu(QMenu):

  def __init__(self, controller, button_count, parent):
    super(OtherPrefixMenu, self).__init__()
    self._controller = controller
    self._button_count = button_count
    self._parent = parent
    self.refresh()

  def refresh(self):
    for i in range(self._button_count, self._controller.prefix_count()):
      prefix = self._controller.get_prefix(i)
      self.addAction(self._make_menu_item(prefix))

    self.addAction(self._make_new_prefix_item())

  def _make_menu_item(self, text):
    action = QAction(text, self)

    def clicked():
      self._controller.to_front(text)
      self._parent.refresh()
      self._parent.select_first()

    action.triggered.connect(clicked)
    return action

  def _make_new_prefix_item(self):
    action = QAction("New Prefix", self)

    def clicked():
      value, ok = QInputDialog.getText(self, "New Prefix", "")

      if not value:
        return

      self._controller.add_prefix(value)
      self._parent.refresh()
      self._parent.select_first()

    action.triggered.connect(clicked)
    return action


def filename_part_of_url(url):
  m = re.search("\/([^\/]+\.[^\/]+)$", url)
  if not m:
    return None
  end = m.group(1)
  m = re.search("^(.*)\?.*$", end)
  if m:
    return m.group(1)
  return end


def construct_target_filename(prefix, url, outdir):
  filename_part = filename_part_of_url(url)
  if len(filename_part) > 200:
    bits = filename.split(".")
    end = bits[-1]
    filename_part = "".join(bits[:-1]).substr(0, 200) + "." + end
  return "%s/%s-%s" % (outdir, prefix, filename_part)


def generate_referer(url):
  parts = urllib.parse.urlparse(url)
  return parts.scheme + "://" + parts.netloc


def download_file(url, outfile):
  referer = generate_referer(url)
  result = subprocess.run(["wget",
                           "-O", outfile,
                           "--referer=%s" % referer,
                           url],
                          capture_output=True)

  if result.returncode == 0:
    return (True, None)
  else:
    return (False, "%s\n\n%s" % (result.stdout, result.stderr))


class WorkerLine(QLineEdit):

  def __init__(self, get_prefix_func, write_log_func, base_dir):
    self._get_prefix = get_prefix_func
    self._write_log = write_log_func
    self._base_dir = base_dir
    super(WorkerLine, self).__init__()
    self._setup()

  def _setup(self):
    self.returnPressed.connect(self._on_return)

  def _on_return(self):
    url = self.text()
    if not self._get_prefix():
      self._write_log("No prefix selected.")
      return
    if not is_url(url):
      self._write_log("The entered text doesn't look like a URL.")
      return
    outfile = construct_target_filename(self._get_prefix(), url, self._base_dir)

    if os.path.exists(outfile):
      self._write_log("-e: %s" % outfile);
      self.clear()
      return
    result, message = download_file(url, outfile)
    if result:
      self._write_log("%s: %s" % (self._get_prefix(), outfile))
      self.clear()
    else:
      self._write_log(message)



class HistoryArea(QTextEdit):

  def __init__(self):
    super(HistoryArea, self).__init__()
    self.setReadOnly(True)

  def WriteHistoryEntry(self, text):
    self.append(text)
    self.append("\n")


class DownloadWindow(QWidget):

  def __init__(self, controller, save_path):
    super(DownloadWindow, self).__init__()
    self._controller = controller
    self._save_path = save_path
    self._setup_widgets()

  def _setup_widgets(self):
    outermost_layout = QVBoxLayout()
    self._history = HistoryArea()
    outermost_layout.addWidget(self._history)
    self.setLayout(outermost_layout)
    self._chooser = PrefixChooser(self._controller)
    outermost_layout.addWidget(self._chooser)
    worker_line = WorkerLine(lambda: self._chooser.get_selected(),
			     self._history.WriteHistoryEntry,
			     self._save_path)
    outermost_layout.addWidget(worker_line)



if __name__ == '__main__':
  app = QApplication([])
  prefix_file = os.environ['HOME'] + "/.prefix_dl_py_prefixes"
  controller = ConfigController(prefix_file)
  widget = DownloadWindow(controller, os.getcwd())
  widget.resize(400, 600)
  widget.show()
  sys.exit(app.exec_())
