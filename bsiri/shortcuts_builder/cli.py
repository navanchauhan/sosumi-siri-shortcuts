import argparse
import os.path

from . import FMT_SHORTCUT, FMT_TOML, Shortcut, VERSION
from .utils import download_shortcut, is_shortcut_url


def convert_shortcut(input_filepath: str, out_filepath: str) -> None:
    '''
    Args:
        input_filepath: input file with a shortcut
        out_filepath: where save the shortcut

    Detects input and output file formats and converts input file into output.
    There is 4 possible (and supported) situations:
        1. URL -> .toml (downloads, converts and saves)
        2. URL -> .shortcut (downloads and saves directly)
        3. toml -> shortcut (converts and saves)
        4. shortcut -> toml (converts and saves)

    Supported URLs are www.icloud.com/shortcuts/... and icloud.com/shortcuts
    '''
    input_format = _get_format(input_filepath)
    out_format = _get_format(out_filepath)

    if input_format == 'url':
        sc_data = download_shortcut(input_filepath)
        if out_format == FMT_SHORTCUT:
            # if output format is .shortcut just save
            # downloaded data without any conversion
            with open(out_filepath, 'wb') as f:
                f.write(sc_data)
            return
        sc = Shortcut.loads(sc_data, file_format=FMT_SHORTCUT)
    else:
        with open(input_filepath, 'rb') as f:
            sc = Shortcut.load(f, file_format=input_format)

    with open(out_filepath, 'wb') as f:
        sc.dump(f, file_format=out_format)


def _get_format(filepath: str) -> str:
    '''
    Args:
        filepath: path for a file which format needs to be determined

    Returns:
        file format (shortcut, toml or url)
    '''
    if is_shortcut_url(filepath):
        return 'url'

    _, ext = os.path.splitext(filepath)
    ext = ext.strip('.')
    if ext in (FMT_SHORTCUT, 'plist'):
        return FMT_SHORTCUT
    elif ext == 'toml':
        return FMT_TOML

    raise RuntimeError(f'Unsupported file format: {filepath}: "{ext}"')


def main():
    parser = argparse.ArgumentParser(description='Shortcuts: Siri shortcuts creator')
    parser.add_argument(
        'file', nargs='?', help='Input file: *.(toml|shortcut|itunes url)'
    )
    parser.add_argument('output', nargs='?', help='Output file: *.(toml|shortcut)')
    parser.add_argument('--version', action='store_true', help='Version information')

    args = parser.parse_args()

    if not any([args.version, args.file, args.output]):
        parser.error('the following arguments are required: file, output')

    if args.version:
        print(f'Shortcuts v{VERSION}')
        return

    convert_shortcut(args.file, args.output)


if __name__ == '__main__':
    main()
