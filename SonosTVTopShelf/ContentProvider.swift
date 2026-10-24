import Foundation
import TVServices

/// Fills the Top Shelf with a carousel: one slide per Sonos room that's playing.
///
/// tvOS runs this when it's about to show the Top Shelf, and again when the app calls
/// `TVTopShelfContentProvider.topShelfContentDidChange()`. With nothing playing it
/// returns nil, and tvOS shows the app's static Top Shelf image instead.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let snapshot = SonosSnapshot()
        let rooms = await snapshot.playingRooms()
        guard !rooms.isEmpty else { return nil }

        var items: [TVTopShelfCarouselItem] = []
        var images: [URL] = []
        for room in rooms {
            let item = TVTopShelfCarouselItem(identifier: room.groupId)
            item.contextTitle = room.roomName
            item.title = room.title
            item.summary = [room.artist, room.detail].compactMap { $0 }.joined(separator: " — ")
            if let artworkURL = room.artworkURL {
                // Fall back to the square artwork, cropped by tvOS, if drawing the slide fails.
                let image = await CarouselArtwork.image(for: room, session: snapshot.session)
                if let image { images.append(image) }
                item.setImageURL(image.flatMap(CarouselArtwork.dataURL(for:)) ?? artworkURL, for: [.screenScale1x, .screenScale2x])
            }
            // Selecting a slide opens the app.
            item.displayAction = TVTopShelfAction(url: URL(string: "sonostv://now-playing")!)
            items.append(item)
        }
        CarouselArtwork.removeAll(except: images)
        return TVTopShelfCarouselContent(style: .details, items: items)
    }
}
