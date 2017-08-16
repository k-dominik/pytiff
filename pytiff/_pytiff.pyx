#cython: c_string_type=str, c_string_encoding=ascii
"""
pytiff is a python wrapper for the libtiff c api written in cython. It is python 2 and 3 compatible.
While there are some missing features, it supports reading chunks of tiled greyscale tif images as well as basic reading for color images.
Apart from that multipage tiffs are supported. It also supports writing greyscale images in tiles or scanlines.
"""

cimport ctiff
from libcpp.string cimport string
import logging
from cpython cimport bool
cimport numpy as np
import numpy as np
from math import ceil
import re
from contextlib import contextmanager
from pytiff._version import _package

TYPE_MAP = {
  1: {
    8: np.uint8,
    16: np.uint16,
    32: np.uint32,
    64: np.uint64
  },
  2: {
    8: np.int8,
    16: np.int16,
    32: np.int32,
    64: np.int64
  },
  3: {
    8: None,
    16: np.float16,
    32: np.float32,
    64: np.float64
  }
}

# map data type to (sample_format, bitspersample)
INVERSE_TYPE_MAP = {
  np.dtype('uint8'): (1, 8),
  np.dtype('uint16'): (1, 16),
  np.dtype('uint32'): (1, 32),
  np.dtype('uint64'): (1, 64),
  np.dtype('int8'): (2, 8),
  np.dtype('int16'): (2, 16),
  np.dtype('int32'): (2, 32),
  np.dtype('int64'): (2, 64),
  np.dtype('float16'): (3, 16),
  np.dtype('float32'): (3, 32),
  np.dtype('float64'): (3, 64)
}

cdef unsigned int SAMPLE_FORMAT = 339
cdef unsigned int SAMPLES_PER_PIXEL = 277
cdef unsigned int BITSPERSAMPLE = 258
cdef unsigned int IMAGEWIDTH = 256
cdef unsigned int IMAGELENGTH = 257
cdef unsigned int TILEWIDTH = 322
cdef unsigned int TILELENGTH = 323
cdef unsigned int EXTRA_SAMPLES = 338
cdef unsigned int TILE_LENGTH = 323
cdef unsigned int TILE_WIDTH =322
cdef unsigned int COMPRESSION = 259
cdef unsigned int PHOTOMETRIC = 262
cdef unsigned int PLANARCONFIG = 284
cdef unsigned int MIN_IS_BLACK = 1
cdef unsigned int MIN_IS_WHITE = 0
cdef unsigned int NO_COMPRESSION = 1

def tiff_version_raw():
  """Return the raw version string of libtiff."""
  return ctiff.TIFFGetVersion()

def tiff_version():
  """Parse the version of libtiff and return it."""
  cdef string str_version = tiff_version_raw()
  m = re.search("(?<=[Vv]ersion )\d+\.\d+\.?\d*", str_version)
  return m.group(0)

class NotTiledError(Exception):
  def __init__(self, message):
    self.message = message

cdef _get_rgb(np.ndarray[np.uint32_t, ndim=2] inp):
  shape = (inp.shape[0], inp.shape[1], 4)
  cdef np.ndarray[np.uint8_t, ndim=3] rgb = np.zeros(shape, np.uint8)

  cdef unsigned long int row, col
  for row in range(shape[0]):
    for col in range(shape[1]):
      rgb[row, col, 0] = ctiff.TIFFGetR(inp[row, col])
      rgb[row, col, 1] = ctiff.TIFFGetG(inp[row, col])
      rgb[row, col, 2] = ctiff.TIFFGetB(inp[row, col])
      rgb[row, col, 3] = ctiff.TIFFGetA(inp[row, col])

  return rgb

cdef class Tiff:
  """The Tiff class handles tiff files.

  The class is able to read chunked greyscale images as well as basic reading of color images.
  Currently writing tiff files is not supported.

  Examples:
    >>> with pytiff.Tiff("tiff_file.tif") as f:
    >>>   chunk = f[100:300, 50:100]
    >>>   print(type(chunk))
    >>>   print(chunk.shape)
    numpy.ndarray
    (200, 50)

  Args:
    filename (string): The filename of the tiff file.
    file_mode (string): File mode either "w" for writing or "r" for reading. Default: "r".
    bigiff (bool): If True the file is assumed to be bigtiff. Default: False.
  """
  cdef ctiff.TIFF* tiff_handle
  cdef public short samples_per_pixel
  cdef short[:] n_bits_view
  cdef short sample_format, n_pages, extra_samples, _write_mode_n_pages
  cdef bool closed, cached
  cdef unsigned int image_width, image_length, tile_width, tile_length
  cdef object cache, logger
  cdef public object filename
  cdef object file_mode

  def __cinit__(self, filename, file_mode="r", bigtiff=False):
    if bigtiff:
      file_mode += "8"
    tmp_filename = <string> filename
    tmp_mode = <string> file_mode
    self.closed = True
    self.filename = tmp_filename
    self.file_mode = tmp_mode
    self._write_mode_n_pages = 0
    self.n_pages = 0
    self.tiff_handle = ctiff.TIFFOpen(tmp_filename.c_str(), tmp_mode.c_str())
    if self.tiff_handle is NULL:
      raise IOError("file not found!")
    self.closed = False

    self.logger = logging.getLogger(_package)
    self.logger.debug("Tiff object created. file: {}".format(filename))
    cdef np.ndarray[np.int16_t, ndim=1] write_pages_buffer = np.zeros(2, dtype=np.int16)
    if self.file_mode == "r":
      self._init_page()

  def _init_page(self):
    """Initialize page specific attributes."""
    self.logger.debug("_init_page called.")
    self.samples_per_pixel = 1
    ctiff.TIFFGetField(self.tiff_handle, SAMPLES_PER_PIXEL, &self.samples_per_pixel)
    cdef np.ndarray[np.int16_t, ndim=1] bits_buffer = np.zeros(self.samples_per_pixel, dtype=np.int16)
    ctiff.TIFFGetField(self.tiff_handle, BITSPERSAMPLE, <ctiff.ttag_t*>bits_buffer.data)
    self.n_bits_view = bits_buffer

    self.sample_format = 1
    ctiff.TIFFGetField(self.tiff_handle, SAMPLE_FORMAT, &self.sample_format)

    ctiff.TIFFGetField(self.tiff_handle, IMAGEWIDTH, &self.image_width)
    ctiff.TIFFGetField(self.tiff_handle, IMAGELENGTH, &self.image_length)

    ctiff.TIFFGetField(self.tiff_handle, TILEWIDTH, &self.tile_width)
    ctiff.TIFFGetField(self.tiff_handle, TILELENGTH, &self.tile_length)

    # get extra samples
    cdef np.ndarray[np.int16_t, ndim=1] extra = -np.ones(self.samples_per_pixel, dtype=np.int16)
    ctiff.TIFFGetField(self.tiff_handle, EXTRA_SAMPLES, <short *>extra.data)
    self.extra_samples = 0
    for i in range(self.samples_per_pixel):
      if extra[i] != -1:
        self.extra_samples += 1

    self.cached = False

  def close(self):
    """Close the filehandle."""
    if not self.closed:
      self.logger.debug("Closing file manually. file: {}".format(self.filename))
      ctiff.TIFFClose(self.tiff_handle)
      self.closed = True
      return

  def __dealloc__(self):
    if not self.closed:
      self.logger.debug("Closing file automatically. file: {}".format(self.filename))
      ctiff.TIFFClose(self.tiff_handle)

  @property
  def mode(self):
    """Mode of the current image. Can either be 'rgb' or 'greyscale'.

    'rgb' is returned if the sampels per pixel are larger than 1. This means 'rgb' is always returned
    if the image is not 'greyscale'.
    """
    if self.samples_per_pixel > 1:
      return "rgb"
    else:
      return "greyscale"

  @property
  def size(self):
    """Returns a tuple with the current image size.

    size is equal to numpys shape attribute.

    Returns:
      tuple: `(image height, image width)`

      This is equal to:
      `(number_of_rows, number_of_columns)`
    """
    return self.image_length, self.image_width

  @property
  def shape(self):
    """The shape property is an alias for the size property."""
    return self.size

  @property
  def n_bits(self):
    """Returns an array with the bit size for each sample of a pixel."""
    return np.array(self.n_bits_view)

  @property
  def dtype(self):
    """Maps the image data type to an according numpy type.

    Returns:
      type: numpy dtype of the image.

      If the mode is 'rgb', the dtype is always uint8. Most times a rgb image is saved as a
      uint32 array. One value is containing all four values of an RGBA image. Thus the dtype of the numpy array
      is uint8.

      If the mode is 'greyscale', the dtype is the type of the first sample.
      Since greyscale images only have one sample per pixel, this resembles the general dtype.
    """
    if self.mode == "rgb":
      self.logger.debug("RGB Image assumed for dtype.")
      return np.uint8
    return TYPE_MAP[self.sample_format][self.n_bits[0]]

  @property
  def current_page(self):
    """Current page/directory of the tiff file.

    Returns:
      int: index of the current page/directory.
    """
    return ctiff.TIFFCurrentDirectory(self.tiff_handle)

  def set_page(self, value):
    """Set the page/directory of the tiff file.

    Args:
      value (int): page index
    """
    ctiff.TIFFSetDirectory(self.tiff_handle, value)
    self._init_page()

  @property
  def number_of_pages(self):
    """number of pages/directories in the tiff file.

    Returns:
      int: number of pages/directories
    """
    # dont use
    # fails if only one directory
    # ctiff.TIFFNumberOfDirectories(self.tiff_handle)
    if self.file_mode == "r":
      return self._number_of_pages_readmode()
    else:
      return self._number_of_pages_writemode()

  def _number_of_pages_readmode(self):
    current_dir = self.current_page
    if self.n_pages != 0:
      return self.n_pages
    else:
      cont = 1
      while cont:
        self.n_pages += 1
        cont = ctiff.TIFFReadDirectory(self.tiff_handle)
      ctiff.TIFFSetDirectory(self.tiff_handle, current_dir)
    return self.n_pages

  def _number_of_pages_writemode(self):
    return self._write_mode_n_pages

  @property
  def n_samples(self):
    cdef short samples_in_file = self.samples_per_pixel - self.extra_samples
    return samples_in_file

  def is_tiled(self):
    """Return True if image is tiled, else False."""
    cdef np.ndarray buffer = np.zeros((self.tile_length, self.tile_width, self.samples_per_pixel - self.extra_samples),dtype=self.dtype).squeeze()
    cdef ctiff.tsize_t bytes = ctiff.TIFFReadTile(self.tiff_handle, <void *>buffer.data, 0, 0, 0, 0)
    if bytes == -1 or not self.tile_width:
      return False
    return True

  def __enter__(self):
    return self

  def __exit__(self, type, value, traceback):
    self.close()

  def __iter__(self):
    for i in range(self.number_of_pages):
      self.set_page(i)
      yield self

  def _load_all(self):
    """Load the image at once.

    If n_samples > 1 a rgba image is returned, else a greyscale image is assumed.

    Returns:
      array_like: RGBA image (3 dimensions) or Greyscale (2 dimensions)
    """
    if self.cached:
      return self.cache
    if self.n_samples > 1:
      data = self._load_all_rgba()
    else:
      data = self._load_all_grey()

    self.cache = data
    self.cached = True
    return data

  def _load_all_rgba(self):
    """Loads an image at once. Returns an RGBA image."""
    self.logger.debug("Loading a whole rgba image.")
    cdef np.ndarray buffer
    shape = self.size
    buffer = np.zeros(shape, dtype=np.uint32)
    ctiff.TIFFReadRGBAImage(self.tiff_handle, self.image_width, self.image_length, <unsigned int*>buffer.data, 0)
    rgb = _get_rgb(buffer)
    rgb = np.flipud(rgb)
    return rgb

  def _load_all_grey(self):
    """Loads an image at once. Returns a greyscale image."""
    self.logger.debug("Loading a whole greyscale image.")
    cdef np.ndarray total = np.zeros(self.size, dtype=self.dtype)
    cdef np.ndarray buffer = np.zeros(self.image_width, dtype=self.dtype)

    for i in range(self.image_length):
      ctiff.TIFFReadScanline(self.tiff_handle,<void*> buffer.data, i, 0)
      total[i] = buffer
    return total

  def _load_tiled(self, y_range, x_range):
    self.logger.debug("Loading tiled image. RGBA is assumed as RGBA,RGBA... for each pixel.")
    cdef unsigned int z_size, start_x, start_y, start_x_offset, start_y_offset
    cdef unsigned int end_x, end_y, end_x_offset, end_y_offset
    if not self.tile_width:
      raise NotTiledError("Image is not tiled!")

    # use rgba if no greyscale image
    z_size = self.n_samples

    shape = (y_range[1] - y_range[0], x_range[1] - x_range[0], z_size)

    start_x = x_range[0] // self.tile_width
    start_y = y_range[0] // self.tile_length
    end_x = ceil(float(x_range[1]) / self.tile_width)
    end_y = ceil(float(y_range[1]) / self.tile_length)
    offset_x = start_x * self.tile_width
    offset_y = start_y * self.tile_length

    large = (end_y - start_y) * self.tile_length, (end_x - start_x) * self.tile_width, z_size

    cdef np.ndarray large_buf = np.zeros(large, dtype=self.dtype).squeeze()
    cdef np.ndarray arr_buf = np.zeros(shape, dtype=self.dtype).squeeze()
    cdef unsigned int np_x, np_y
    np_x = 0
    np_y = 0
    for current_y in np.arange(start_y, end_y):
      np_x = 0
      for current_x in np.arange(start_x, end_x):
        real_x = current_x * self.tile_width
        real_y = current_y * self.tile_length
        tmp = self._read_tile(real_y, real_x)
        e_x = np_x + tmp.shape[1]
        e_y = np_y + tmp.shape[0]

        large_buf[np_y:e_y, np_x:e_x] = tmp
        np_x += self.tile_width

      np_y += self.tile_length

    arr_buf = large_buf[y_range[0]-offset_y:y_range[1]-offset_y, x_range[0]-offset_x:x_range[1]-offset_x]
    return arr_buf

  def _get(self, y_range=None, x_range=None):
    """Function to load a chunk of an image.

    Should not be used. Instead use numpy style slicing.

    Examples:
      >>> with pytiff.Tiff("tiffile.tif") as f:
      >>>   total = f[:, :] # f[:]
      >>>   part = f[100:200,:]
    """

    if x_range is None:
      x_range = (0, self.image_width)
    if y_range is None:
      y_range = (0, self.image_length)

    cdef np.ndarray res, tmp
    try:
      res = self._load_tiled(y_range, x_range)
    except NotTiledError as e:
      self.logger.debug(e.message)
      self.logger.debug("Warning: chunks not available! Loading all data!")
      tmp = self._load_all()
      res = tmp[y_range[0]:y_range[1], x_range[0]:x_range[1]]

    return res

  def __getitem__(self, index):
    if not isinstance(index, tuple):
      if isinstance(index, slice):
        index = (index, slice(None,None,None))
      else:
        raise Exception("Only slicing is supported")
    elif len(index) < 3:
      index = index[0],index[1],0

    if not isinstance(index[0], slice) or not isinstance(index[1], slice):
      raise Exception("Only slicing is supported")

    x_range = np.array((index[1].start, index[1].stop))
    if x_range[0] is None:
      x_range[0] = 0
    if x_range[1] is None:
      x_range[1] = self.image_width

    y_range = np.array((index[0].start, index[0].stop))
    if y_range[0] is None:
      y_range[0] = 0
    if y_range[1] is None:
      y_range[1] = self.image_length

    return self._get(y_range, x_range)

  def __array__(self, dtype=None):
    return self.__getitem__(slice(None))

  @contextmanager
  def get_write_page(self, shape, dtype, tile_length, tile_width, **options):
    self._setup_page(shape, dtype, tile_lenght=tile_length, tile_width=tile_width, **options)
    try:
      yield self
    finally:
      self._finalize_page()

  def _setup_page(self, shape, dtype, **options):
    print('current_page:', self.current_page)
    if len(shape) > 2:
      raise NotImplementedError("Only grayscale image implemented.")
    if "w" not in self.file_mode:
      raise Exception("Write is only supported in .. write mode ..")

    cdef short photometric, planar_config, compression
    cdef short sample_format, nbits
    photometric = options.get("photometric", MIN_IS_BLACK)
    planar_config = options.get("planar_config", 1)
    compression = options.get("compression", NO_COMPRESSION)

    sample_format, nbits = INVERSE_TYPE_MAP[dtype]

    ctiff.TIFFSetField(self.tiff_handle, 274, 1) # Image orientation , top left
    ctiff.TIFFSetField(self.tiff_handle, SAMPLES_PER_PIXEL, 1)
    ctiff.TIFFSetField(self.tiff_handle, BITSPERSAMPLE, nbits)

    cdef unsigned short slen, swid

    slen = int(shape[0])
    swid = int(shape[1])
    ctiff.TIFFSetField(self.tiff_handle, IMAGELENGTH, slen)
    ctiff.TIFFSetField(self.tiff_handle, IMAGEWIDTH, swid)
    ctiff.TIFFSetField(self.tiff_handle, SAMPLE_FORMAT, sample_format)
    ctiff.TIFFSetField(self.tiff_handle, COMPRESSION, compression) # compression, 1 == no compression
    ctiff.TIFFSetField(self.tiff_handle, PHOTOMETRIC, photometric) # photometric, minisblack
    ctiff.TIFFSetField(self.tiff_handle, PLANARCONFIG, planar_config) # planarconfig, contiguous not needed for gray

    cdef unsigned short tile_length, tile_width
    tile_length = options.get("tile_length", 256)
    tile_width = options.get("tile_width", 256)

    ctiff.TIFFSetField(self.tiff_handle, TILE_LENGTH, tile_length)
    ctiff.TIFFSetField(self.tiff_handle, TILE_WIDTH, tile_width)


  def _finalize_page(self):
    ctiff.TIFFWriteDirectory(self.tiff_handle)
    self._write_mode_n_pages += 1
  
  def _write_tile(self, np.ndarray data, np.ndarray data_position):
    """
    assumes tiles are already in the right shape
    """
    cdef unsigned short x, y
    x = int(data_position[1])
    y = int(data_position[0])
    print('position', x, y)

    ctiff.TIFFWriteTile(self.tiff_handle, <void *> data.data, x, y, 0, 0)


  def write(self, np.ndarray data, shape=None, data_position=None, **options):
    """Write data to the tif file.

    If the file is opened in write mode, a numpy array can be written to a
    tiff page. Currently RGB images are not supported.
    Multipage tiffs are supperted by calling write multiple times.

    Args:
        data (array_like): 2D numpy array. Supported dtypes: un(signed) integer, float.
        method: determines which method is used for writing. Either "tile" for tiled tiffs or "scanline" for basic scanline tiffs. Default: "tile"
        photometric: determines how values are interpreted, either zero == black or zero == white.
                     MIN_IS_BLACK(default), MIN_IS_WHITE. more information can be found in the libtiff doc.
        planar_config: defaults to 1, component values for each pixel are stored contiguously.
                      2 says components are stored in component planes. Irrelevant for greyscale images.
        compression: compression level. defaults to no compression. More information can be found in the libtiff doc.
        tile_length: Only needed if method is "tile", sets the length of a tile. Must be a multiple of 16. Default: 256
        tile_width: Only needed if method is "tile", sets the width of a tile. Must be a multiple of 16. Default: 256

    Examples:
      >>> data = np.random.rand(100,100)
      >>> # data = np.random.randint(size=(100,100))
      >>> with pytiff.Tiff("example.tif", "w") as handle:
      >>>   handle.write(data, method="tile", tile_length=240, tile_width=240)
    """
    print('current_page:', self.current_page)
    if data.ndim > 2:
      raise NotImplementedError("Only grayscale image implemented.")
    if "w" not in self.file_mode:
      raise Exception("Write is only supported in .. write mode ..")
    if shape is not None:
      assert data_position is not None, "data position must be given"

    cdef short photometric, planar_config, compression
    cdef short sample_format, nbits
    photometric = options.get("photometric", MIN_IS_BLACK)
    planar_config = options.get("planar_config", 1)
    compression = options.get("compression", NO_COMPRESSION)

    sample_format, nbits = INVERSE_TYPE_MAP[data.dtype]

    ctiff.TIFFSetField(self.tiff_handle, 274, 1) # Image orientation , top left
    ctiff.TIFFSetField(self.tiff_handle, SAMPLES_PER_PIXEL, 1)
    ctiff.TIFFSetField(self.tiff_handle, BITSPERSAMPLE, nbits)

    cdef short slen, swid

    if shape is None:
      print('setting shape from data')
      ctiff.TIFFSetField(self.tiff_handle, IMAGELENGTH, data.shape[0])
      ctiff.TIFFSetField(self.tiff_handle, IMAGEWIDTH, data.shape[1])
    else:
      print('setting shape from shape')
      slen = int(shape[0])
      swid = int(shape[1])
      ctiff.TIFFSetField(self.tiff_handle, IMAGELENGTH, slen)
      ctiff.TIFFSetField(self.tiff_handle, IMAGEWIDTH, swid)
    ctiff.TIFFSetField(self.tiff_handle, SAMPLE_FORMAT, sample_format)
    ctiff.TIFFSetField(self.tiff_handle, COMPRESSION, compression) # compression, 1 == no compression
    ctiff.TIFFSetField(self.tiff_handle, PHOTOMETRIC, photometric) # photometric, minisblack
    ctiff.TIFFSetField(self.tiff_handle, PLANARCONFIG, planar_config) # planarconfig, contiguous not needed for gray

    write_method = options.get("method", "tile")

    if shape is not None:
      'writing data in tile mode'
      self._write_tile(data, data_position)
    else:
      if write_method == "tile":
        self._write_tiles(data, **options)
      elif write_method == "scanline":
        self._write_scanline(data, **options)

      self._write_mode_n_pages += 1

  def _write_tiles(self, np.ndarray data, **options):
    cdef short tile_length, tile_width
    tile_length = options.get("tile_length", 240)
    tile_width = options.get("tile_width", 240)

    ctiff.TIFFSetField(self.tiff_handle, TILE_LENGTH, tile_length)
    ctiff.TIFFSetField(self.tiff_handle, TILE_WIDTH, tile_width)

    cdef np.ndarray buffer
    n_tile_rows = int(np.ceil(data.shape[0] / float(tile_length)))
    n_tile_cols = int(np.ceil(data.shape[1] / float(tile_width)))

    cdef unsigned int x, y
    for i in range(n_tile_rows):
      for j in range(n_tile_cols):
        y = i * tile_length
        x = j * tile_width
        buffer = data[y:(i+1)*tile_length, x:(j+1)*tile_width]
        buffer = np.pad(buffer, ((0, tile_length - buffer.shape[0]), (0, tile_width - buffer.shape[1])), "constant", constant_values=(0))

        ctiff.TIFFWriteTile(self.tiff_handle, <void *> buffer.data, x, y, 0, 0)

    ctiff.TIFFWriteDirectory(self.tiff_handle)



    # ctiff.TIFFWriteDirectory(self.tiff_handle)


  def _write_scanline(self, np.ndarray data, **options):
      ctiff.TIFFSetField(self.tiff_handle, 278, ctiff.TIFFDefaultStripSize(self.tiff_handle, data.shape[1])) # rows per strip, use tiff function for estimate
      cdef np.ndarray row
      for i in range(data.shape[0]):
        row = data[i]
        ctiff.TIFFWriteScanline(self.tiff_handle, <void *>row.data, i, 0)
      ctiff.TIFFWriteDirectory(self.tiff_handle)

  cdef _read_tile(self, unsigned int y, unsigned int x):
    cdef np.ndarray buffer = np.zeros((self.tile_length, self.tile_width, self.n_samples),dtype=self.dtype).squeeze()
    cdef ctiff.tsize_t bytes = ctiff.TIFFReadTile(self.tiff_handle, <void *>buffer.data, x, y, 0, 0)
    if bytes == -1:
      raise NotTiledError("Tiled reading not possible")
    return buffer
