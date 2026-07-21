struct EntityAccessor:
    var _entity: Entity


world._entities[entity.get_id()]

struct World[*ComponentTypes: ComponentType]:
    var _entity_locations: List[EntityLocation]

    def __init__(out self):
        self._entities = []

    def add_entities[
        *ComponentTypes: ComponentType
    ](mut self, *components, count) -> List[Entity]:
        ...

    def remove_entities(mut self, entities: List[Entity]):
        ...

    def is_alive(self, entity: Entity) -> Bool:
        ...
